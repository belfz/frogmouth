# frogmouth — single-track timeline design

Status: implemented first-timeline-release contract following the July 2026 design interview.

This document describes frogmouth's active lightweight, project-based editor with one gapless sequence of clips. The former session-only design is retained only as an [archived historical record](TECHNICAL_DESIGN.md). The ordered implementation history and deferred backlog are in [TIMELINE_IMPLEMENTATION_TASKS.md](TIMELINE_IMPLEMENTATION_TASKS.md).

## 1. Product boundary

### Goals

- Import up to 25 external source files into a project Media Library.
- Build one gapless timeline containing up to 50 clips and 30 minutes of edited material.
- Create clips from several files, several ranges of one file, or a combination of both.
- Append a whole source to the timeline, split at the playhead, trim non-destructively, duplicate, reorder, and ripple-delete clips.
- Keep source audio permanently linked to video.
- Apply one or more stabilization passes to the selected clip.
- Preview the composition and export the complete timeline as a high-quality HEVC MP4.
- Save a lightweight, human-readable `.frogmouth` JSON project.
- Make every committed project edit undoable during the current app session.

### Explicit non-goals for the first timeline release

- Multiple or overlapping video/audio tracks, overlays, picture-in-picture, detached audio, or audio-only clips.
- Gaps, black generators, or arbitrary timeline start timecode.
- Transitions; every video boundary is a hard cut.
- Titles, speed changes, colour controls, independent audio controls, or per-clip volume.
- Source-monitor in/out selection before insertion; the entire source is inserted and then edited on the timeline.
- Audio waveforms, selected-range export, recent projects, extensive editing shortcuts, or persisted undo history.
- Simultaneously open project windows.
- Offline editing or an in-app media-relink workflow.
- Automatic conversion between incompatible SDR, HDR, Log, or colour-primary combinations.
- Custom timeline canvas/output settings.

Multiple tracks are not merely deferred: they are outside the expected product direction. The domain model should avoid gratuitously preventing a future migration, but it must not pay multi-track complexity today.

## 2. Confirmed interaction decisions

### Editor layout

- Left: Media Library and import controls.
- Centre: shared timeline viewer and playback controls.
- Right: selected-clip inspector, including stabilization state and actions.
- Bottom: horizontally scrollable and zoomable timeline with thumbnail filmstrips and a vertical playhead.
- Sidebars are collapsible and their layout may evolve later.

The startup screen offers **New Project** and **Open Project…**. Dropping a `.frogmouth` file opens it. Dropping video files creates an untitled project, imports them, and appends them in dropped order. Recent Projects is deferred.

### Media Library

Each external file is represented once by a stable media-asset ID. A row shows an original-source thumbnail, filename, duration, and compact technical details. The same asset may back any number of timeline clips. Dragging inserts the whole source at a timeline boundary; an append action adds it at the end.

Removing a source that is still referenced by timeline clips is refused with an explanation and usage count. The user must delete the clips first. Importing and removing an unused source are undoable project edits.

### Gapless clip editing

The timeline is an ordered array, not a set of clips with stored horizontal positions. A clip's timeline start is derived from the sum of preceding durations. Trimming or deletion therefore ripples all later clips automatically.

- Only one clip is selected at a time.
- A split occurs at the frame-aligned playhead and produces two adjacent clips referencing the corresponding source ranges.
- A trim changes the selected clip's source-in or source-out boundary and may later be extended again up to its available source bounds.
- During a trim drag the UI holds a transient candidate state and ripples the layout live.
- Releasing the pointer commits the whole gesture as one undo operation; cancelling restores its starting state.
- **Confirm Trim** is removed entirely.
- Reorder, duplicate, split, ripple-delete, import, library removal, and stabilization changes each create one undoable command.

### Timeline navigation

- Clip width represents duration at the current zoom.
- A zoom slider, trackpad pinch, and **Fit Timeline** control are included.
- Zoom is anchored near the playhead or pointer rather than the left edge.
- The timeline scrolls horizontally and supports click/drag scrubbing.
- The playhead and clip edges snap to meaningful boundaries; a modifier temporarily disables snapping.
- Time labels use `HH:MM:SS:FF` and adapt their density to zoom.
- Comprehensive keyboard editing is deferred, apart from standard macOS open/save/undo/redo and existing playback behavior.

Timeline thumbnails are always sampled from original source media. They do not regenerate to depict stabilization crop; stabilization icons communicate effect state.

## 3. Exact-time domain model

The current `TimeInterval`/`Double` edit model is not precise enough for repeated splits and concatenation. Persist rational media times and convert to `CMTime` at the AVFoundation boundary.

`MediaTime` and `FrameRate` normalize numerator/denominator pairs by their greatest common divisor and reject non-positive scales. Arithmetic uses checked integer operations and reports overflow instead of falling back to floating point. `CMTime` conversion copies integer value/timescale directly and rejects non-numeric values and non-zero epochs.

```swift
struct MediaTime: Codable, Hashable, Sendable {
    var value: Int64
    var timescale: Int32
}

struct MediaTimeRange: Codable, Hashable, Sendable {
    var start: MediaTime
    var duration: MediaTime
}

struct TimelineFormat: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var frameRate: FrameRate
    var colour: VideoColourMetadata
    var audioSampleRate: Int
    var audioChannelCount: Int
}

struct MediaAsset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var path: MediaPathReference
    var fingerprint: MediaFingerprint
    var inspected: PersistedMediaFacts
}

struct TimelineClip: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var assetID: MediaAsset.ID
    var sourceRange: MediaTimeRange
    var stabilizationPasses: [StabilizationEffect]
}

struct ProjectState: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var name: String
    var mediaLibrary: [MediaAsset]
    var timelineFormat: TimelineFormat?
    var clips: [TimelineClip]
}
```

The first inserted clip establishes `TimelineFormat`. Removing every clip does not silently change it; a future explicit project-settings workflow may do so. Frame rate must be a rational such as `60000/1001`, never a rounded `Double`.

`TimelineIndex` derives each clip's start and duration as integer timeline-frame counts, then exposes rational ranges for downstream builders. Clip positions are never stored. Every `ProjectCommand` edits a candidate value, rebuilds the index, and replaces the current `ProjectState` only after complete validation, so a failed command cannot partially mutate the editor. A silent first clip establishes the default 48 kHz/stereo audio-conformance baseline; an all-silent export still omits audio as specified later.

All structural edits snap to timeline frame boundaries. When a source frame rate differs, one shared conversion policy maps timeline time to the closest valid source/media time using documented `CMTime` rounding. A clip must contain at least one timeline frame. Split is disabled on either edge.

Split takes a frame offset within the selected clip, maps it to the nearest source frame, and verifies that the two independently conformed children contain exactly the requested left/right timeline-frame counts. A boundary that cannot be represented at the source rate is refused rather than moving the cut or changing total duration silently. Both children cover the parent source range exactly and inherit its complete stabilization-pass array.

The implemented rounding policies are explicitly named `towardNegativeInfinity`, `towardPositiveInfinity`, and `nearestTiesAwayFromZero`; timeline duration conformance and ordinary playhead/source mapping use the latter. `HH:MM:SS:FF` uses nominal-rate, non-drop-frame counting, including for 24000/1001, 30000/1001, and 60000/1001. A later drop-frame display, if desired, must be a separate explicit format using a semicolon rather than silently changing persisted timing.

The exact source range remains expressed in its native rational time. Its timeline duration is the nearest whole number of timeline frames, so conformance can adjust duration by at most half a timeline frame. AVFoundation scales the inserted composition segment—including linked audio—to that snapped duration. FFmpeg applies the equivalent frame-rate/timestamp normalization and a matching audio tempo adjustment. This avoids fractional final frames and keeps every cut addressable by `HH:MM:SS:FF`.

Selection, hover, playhead, zoom, transient drag state, processing progress, active player item, and undo stacks are UI/session state and are not serialized.

## 4. Lightweight JSON project

`.frogmouth` is a single UTF-8 JSON file. It contains edit decisions and media references, never source media or generated binary data.

Illustrative shape:

```json
{
  "schemaVersion": 1,
  "id": "A-PROJECT-UUID",
  "name": "Wildlife Morning",
  "mediaLibrary": [
    {
      "id": "AN-ASSET-UUID",
      "path": {
        "relativeToProject": "Media/bird.MP4",
        "absoluteFallback": "/Volumes/Footage/Media/bird.MP4"
      },
      "fingerprint": {
        "fileSize": 123456789,
        "modificationTimeNanoseconds": 1784023200000000000
      },
      "inspected": {
        "duration": { "value": 4431, "timescale": 200 },
        "width": 4096,
        "height": 2160,
        "frameRate": { "numerator": 60000, "denominator": 1001 },
        "videoBitrate": 120000000,
        "videoCodec": "avc1",
        "audioCodec": "aac",
        "audioSampleRate": 48000,
        "audioChannelCount": 2,
        "colour": {
          "primaries": "bt709",
          "transfer": "bt709",
          "matrix": "bt709",
          "range": "full"
        }
      }
    }
  ],
  "timelineFormat": {
    "width": 4096,
    "height": 2160,
    "frameRate": { "numerator": 60000, "denominator": 1001 },
    "colour": {
      "primaries": "bt709",
      "transfer": "bt709",
      "matrix": "bt709",
      "range": "full"
    },
    "audioSampleRate": 48000,
    "audioChannelCount": 2
  },
  "clips": [
    {
      "id": "A-CLIP-UUID",
      "assetID": "AN-ASSET-UUID",
      "sourceRange": {
        "start": { "value": 0, "timescale": 1 },
        "duration": { "value": 10, "timescale": 1 }
      },
      "stabilizationPasses": []
    }
  ]
}
```

Schema version 1 is locked by the human-readable [`ProjectSchemaV1.frogmouth`](Tests/Fixtures/ProjectSchemaV1.frogmouth) fixture and deterministic round-trip tests. Unknown future fields are ignored where safe; a newer unsupported `schemaVersion` produces an actionable error before partial decoding. `ProjectMigration` and `ProjectMigrationPipeline` define the required sequential migration boundary even though version 1 has no predecessor. Each future schema change requires an explicit migration and before/after fixture.

### Paths and missing sources

Store a path relative to the project when practical, plus an absolute fallback and inexpensive identity facts. On open, resolve and validate every Media Library entry. If any file is absent, keep the project unopened and show one error listing every missing path. The user restores the files externally and retries. There is no offline placeholder or Relink UI initially.

`ProjectMediaResolver` always tries the project-relative candidate first and the absolute fallback second. `MediaFingerprint` is the regular file's exact byte size plus its POSIX modification timestamp in nanoseconds. This is deliberately inexpensive identity detection, not a content hash.

If a file exists but its fingerprint changed, re-inspect it. Accept it only if existing clip ranges and compatibility constraints remain valid; otherwise report the conflict without modifying the project.

`ProjectOpenValidator` performs resolution, fingerprinting, changed-file inspection, range checks, and timeline-colour checks against a candidate `ProjectState`; it returns the candidate and runtime resolved-URL map only after every check succeeds. Missing sources are aggregated before inspection. Changed-source errors name the full resolved path and affected clip IDs, and the caller's decoded state remains untouched so retrying after an external fix is safe.

### Save behavior

- A new timeline starts untitled.
- First `⌘S` presents a `.frogmouth` save location.
- Subsequent committed edits autosave in place after a short debounce.
- Never autosave transient pointer-drag state.
- Write a sibling temporary file, `fsync`/close it, then atomically replace the project.
- **Save As…** writes a new document identity and moves future cache ownership to it without embedding caches.
- Closing an unsaved modified project prompts the user.
- Undo/redo history resets when a project is reopened.
- Only one project window is supported initially.

`ProjectDocumentSession` is the document-lifecycle boundary used by the later UI phase. It owns the value-state editor, the last successfully saved snapshot, the current document URL, resolved runtime media URLs, and a persistent save error. New documents have no URL; plain Save therefore requests a first-save location, while Save As assigns a new project UUID and consistently rewrites the session-local history to that identity. Opening constructs a fresh editor from the fully validated project, so undo and redo never cross sessions.

All manual and automatic writes pass through one actor-isolated `ProjectDocumentStore`. `AtomicProjectFileWriter` creates a hidden sibling temporary file, writes and `fsync`s its complete bytes, closes it, atomically renames it over the destination, and then best-effort `fsync`s the parent directory. A failed write does not advance the saved snapshot or discard the in-memory project. The UI can use `needsCloseConfirmation` whenever the current value differs from the last successful snapshot and display `lastSaveError` until a later save succeeds.

`ProjectAutosaveCoordinator` snapshots only committed project values and debounces them for 750 ms. A newer snapshot cancels an older pending debounce; the document store serializes any write already underway, ensuring the newest scheduled value is written last. Starting a manual Save or Save As cancels pending autosave first. Trim-pointer updates live solely in `TrimTransaction`, so no autosave is scheduled until pointer-up commits the one trim command; undo and redo schedule autosave like any other committed edit.

The Phase 2 application shell owns exactly one `ProjectDocumentSession`. Startup offers **New Project**, **Open Project…**, and creation from one or more videos, with no Recent Projects state. Dropping a `.frogmouth` file requests an open; dropping videos creates an untitled project when none is open and appends full-source clips in drop order. Standard New/Open/Save/Save As/Close/Undo/Redo commands route to the document session, and the FFmpeg startup gate remains in front of the shell.

Replacing or closing a modified project enters one shared Save/Discard/Cancel decision. Save performs first-save location selection when necessary; Discard cancels any pending debounced autosave, restores the last successful snapshot, and clears history before continuing. The window close button uses the same decision rather than bypassing it. Imported runtime URLs are reconciled as media-library edits move through apply, undo, and redo, while only portable path references remain in project JSON.

## 5. Media compatibility and conformance

The first timeline clip establishes the output canvas, frame rate, colour signature, and baseline audio format.

For compatible colour sources with different dimensions, aspect ratios, or frame rates:

- Preserve aspect ratio.
- Scale to fit within the timeline canvas.
- Centre-pad unused area with black.
- Convert to the timeline frame rate.
- Normalize sample aspect ratio and timestamps.
- Resample audio and conform channel layout for concatenation.

`TimelineCompatibilityValidator` calculates the aspect-fit dimensions with checked integer arithmetic and nearest-pixel rounding, then divides odd padding with the extra pixel on the right or bottom. Its conformance facts separately report frame-rate conversion, audio resampling, and channel-layout conversion. AVFoundation inspection persists rational frame rate from the track's exact minimum frame duration; common-rate matching is only a fallback when the framework does not provide a usable duration.

### Known colour-management trade-off

The first timeline release intentionally rejects sources whose colour characteristics are incompatible with the first clip. Resolution and frame-rate normalization are mechanical; silent HDR/SDR, Log, transfer-function, matrix, range, or primaries conversion could visibly damage footage.

`VideoColourMetadata` includes primaries, transfer function, matrix, and full/limited range. Known Apple, FFmpeg, numeric, punctuation, and case aliases normalize to canonical semantic values before comparison. All four normalized values must then be exactly equal.

Missing/unspecified matches only missing/unspecified. An unrecognized tag matches only the same punctuation/case-normalized unrecognized tag. A known value never matches missing or unrecognized metadata. Accepting two identically missing or unrecognized values is a pragmatic assumption: frogmouth cannot prove their underlying colour characteristics without proper pixel conversion, but it rejects every observable conflict. Primaries, transfer, and matrix are never guessed from resolution or camera model. For compressed H.264/HEVC/MPEG-4 YCbCr, Core Media's absent `FullRangeVideo` flag has its specified limited-range meaning.

Import into the Media Library may succeed, but insertion into an established timeline must list every mismatch as `property (timeline: value; clip: value)`, state that frogmouth does not convert colour spaces yet, and tell the user to choose a clip with matching colour metadata. Proper colour management and explicit conversion controls are deferred. This is a known assumption, not an accidental unsupported case. The executable policy and fixture evidence are recorded in [the T03 validation record](Tests/Spikes/T03_COLOUR_COMPATIBILITY.md).

The project was initialized around Canon EOS R5 footage, but compatibility messages and the UI remain camera-agnostic.

## 6. Stabilization model and persistent cache

Stabilization applies only to the selected clip. Multiple passes remain ordered and implicit initially; a later inspector may expose individual passes.

```swift
struct StabilizationEffect: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var mode: StabilizationMode
    var analysisCoverage: MediaTimeRange
    var processingRevision: Int
}

enum StabilizationStatus {
    case none
    case valid
    case stale(reason: StaleReason)
}
```

Cache file URLs are never serialized. Status is derived by asking the cache store whether every configured pass has compatible transform/proxy artifacts covering the current clip range.

- No stabilization: no icon.
- All passes current: stabilized icon.
- Any pass missing, incompatible, or lacking range coverage: stale icon with tooltip and accessibility label.
- A stale clip previews from its original source, retains its selected modes, and blocks export.
- **Update Stabilization** explicitly rebuilds the necessary pass stack; trimming never starts analysis automatically.
- Stabilization and preview rendering remain modal, cancellable, and editor-blocking initially.

Splitting or duplicating a stabilized clip inherits the complete pass stack. Reordering does not invalidate it. Trimming inward remains covered. Extending outside the analyzed range marks only the extended child stale. Applying a new pass analyzes the valid result of every previous pass.

### Cache layout and identity

Use an app-managed persistent-but-disposable directory such as:

```text
~/Library/Caches/dev.frogmouth.app/projects/<project UUID>/
  assets/<asset UUID>/entries/<SHA-256 cache key>/
    artifact-<generation UUID>.<extension>
    manifest.json
```

Every entry identity contains a namespace and logical artifact ID, the asset UUID and source fingerprint, the frogmouth processing revision, an optional tool revision, and ordered request parameters. `CacheKeyBuilder` deterministically encodes that identity and names the entry with its SHA-256 digest. For stabilization, the ordered parameters must include the analyzed source range, preceding pass configuration, current pass profile, and proxy settings, while the tool revision identifies the FFmpeg/libvidstab combination. A different source fingerprint, processing/tool revision, or ordered configuration therefore cannot address the old entry.

`ProjectCacheStore` atomically writes a uniquely named artifact and then atomically replaces `manifest.json`; the manifest is the commit point. Until it succeeds, a lookup can only observe the previous committed artifact or a miss. Hits validate manifest version, full identity, key, safe relative filename, artifact existence, and byte count. If the exact key is absent, manifests for the same asset/namespace/logical artifact are inspected to report which identity fields changed. Malformed, missing, or incompatible data is disposable stale state, not a project-open failure.

**Clear Project Cache** removes only `projects/<project UUID>` beneath the fixed app cache root. **Clear All Caches** removes only that root's `projects` child. Neither operation consumes a source or document path, and cache URLs never enter project JSON. Cache deletion never corrupts a project; it changes configured stabilization to stale.

The Phase 3 status layer assigns each effect two independently validated identities: an ASCII transform artifact and an audio-linked 1024-pixel preview artifact. Both share the effect UUID, exact analysis domain, ordered predecessor lineage, deterministic mode profile, source fingerprint, processing revision, and FFmpeg executable/tool revision; only the preview identity includes proxy-specific settings. Clip IDs and current inward-trim ranges are deliberately excluded, allowing split and duplicate descendants to reuse the same analyzed lineage. The editor resolves cache status asynchronously, checks range coverage synchronously during live trims, exposes the precise stale reason in the inspector, and treats an unresolved or stale configured pass as export-blocking.

The T17 processing path is transactional at the project boundary. **Apply Steady** and **Apply Natural Motion** append a pass to the selected clip only; each new pass records the clip's current source range as its analysis domain. Earlier passes are applied in order over their recorded domains before the next pass is analyzed, with exact nested-domain trims between passes. FFmpeg then renders a 1024-pixel HEVC proxy for each pass and re-encodes its linked audio as AAC, avoiding the confusing silent-preview optimization. Generated `.trf` and `.mp4` files are copied into the persistent cache without loading the complete proxy into memory, and the manifest is the atomic commit point.

Processing looks up each artifact before running FFmpeg, so reopening a project, undoing, redoing, splitting, duplicating, or inward-trimming can reuse compatible results. A valid descendant maps its original source range into the final proxy relative to that pass's analysis start; a stale or unresolved clip continues previewing from its original source. Trimming never launches analysis. **Update Stabilization** is the explicit repair action: it retains pass IDs and order, expands every pass just enough to cover the current clip, updates the processing revision, and regenerates only cache misses. The blocking progress sheet remains cancellable, and the project command replacing the pass stack is recorded only after all required artifacts succeed. Cancellation or failure therefore preserves the previous project decision and any previously committed cache manifests; unreferenced newly completed artifacts remain disposable cache data.

### First timeline release compatibility record

| Compatibility boundary | Release value | Behavior when it changes |
| --- | ---: | --- |
| `.frogmouth` JSON schema | `1` | Newer schemas are refused before partial decode; older schemas require an explicit sequential migration. |
| Cache manifest schema | `1` | Unsupported manifests are disposable stale cache entries and are rebuilt on demand. |
| Stabilization processing revision | `1` | Existing passes become stale and require **Update Stabilization**. |
| Original-source thumbnail processing revision | `1` | Existing thumbnails miss the new identity and are regenerated lazily. |

Stabilization identities also include the detected FFmpeg/libvidstab tool revision: FFmpeg's
version line, executable size/modification fingerprint, and required-filter marker. Changing
that value invalidates stabilization artifacts without changing project JSON. Cache files are
never migrated or treated as user documents; they may always be deleted and rebuilt. These
release values are pinned by `firstTimelineReleaseCompatibilityRevisionsAreStable` so changing
one requires an intentional schema, migration, or cache-invalidation decision and matching
documentation.

### Transform alignment after split — validated decision

`vidstabdetect` ASCII rows contain frame-relative local-motion observations. `vidstabtransform` integrates and smooths those observations over the complete input domain. A child produced by splitting an analyzed range therefore cannot seek to its own source start and consume a sliced/renumbered parent `.trf`: both the prior integrated path and surrounding smoothing window would change.

The T01 spike in [`validate-stabilization-split.sh`](scripts/spikes/validate-stabilization-split.sh) established the render rule:

1. Each stabilization effect retains the analysis domain on which its transforms were computed.
2. Apply the transform across that complete domain before trimming any descendant clip.
3. Model export as a directed acyclic filter graph. Descendants with a common stabilized lineage share one decoded/transformed prefix, then an FFmpeg `split` branches into their exact child ranges.
4. A later child-specific stabilization pass starts a new effect node after that branch and records the child's then-current domain.
5. Preview proxies likewise cover the effect's analysis domain; child clips map to exact proxy subranges.

This strategy was frame-identical to a full stabilized reference for every child frame at 24 fps and 60000/1001 fps, including first/last boundaries and two stacked passes. Naively sliced local motions differed on 40 of 48 frames in the 24 fps child. On the small fixture, one shared-prefix render took 0.37 seconds versus 0.68 seconds for two repeated full-domain renders at 24 fps, and 0.39 versus 0.74 seconds at 60000/1001. These absolute timings are not production benchmarks; they demonstrate elimination of duplicated work.

Do not slice `.trf` local-motion rows and do not re-analyze on split. Also avoid a full-quality stabilized intermediate: it is unnecessary when one filter graph can share the prefix and would create unacceptable 4K disk usage. Cache identity and render planning must preserve effect-lineage and analysis-domain UUIDs so common prefixes can be recognized after split, duplicate, reorder, save, and reopen. Detailed evidence is in [the T01 spike record](Tests/Spikes/T01_STABILIZATION_SPLIT.md).

## 7. Preview architecture

Use a hybrid architecture:

- SwiftUI for the editor shell and most timeline presentation.
- A focused custom timeline component; bridge to AppKit only if precision or profiling demonstrates a need.
- AVFoundation for interactive playback composition.
- FFmpeg for stabilization processing and final export.

The Phase 2 shell is divided into a collapsible left Media Library, central timeline viewer, collapsible right inspector, and bottom gapless clip strip. Media Library rows are keyed by asset UUID and show a neutral thumbnail placeholder, filename, duration, dimensions, frame rate, and timeline usage count. Importing into an existing project adds sources to the library without silently creating clips; a full source is appended explicitly or dragged anywhere onto the timeline track, where the release position resolves to the nearest insertion boundary. Narrow boundary targets remain available for precise insertion and reorder feedback, and the same asset can be inserted repeatedly. Removal is routed through `removeUnusedMedia`, so a referenced source remains visible and the error reports its exact usage count. Import inspection is asynchronous, ordered, and surfaced as progress rather than blocking the main actor without feedback.

The central region is deliberately a timeline viewer, not a source in/out editor. Library selection exposes source facts in the inspector; timeline selection exposes clip facts. There is no second source playhead or source-range workflow hidden in this shell.

`TimelineViewportMath` converts each derived rational frame position directly to a horizontal pixel coordinate at the current pixels-per-second scale; clip positions are never accumulated from prior floating-point widths. The timeline uses a narrow `NSScrollView` bridge for native trackpad scrolling and exact content offsets while clip/ruler/playhead content stays SwiftUI. Zoom is logarithmic from overview to frame detail, works from the slider or pinch gesture, and recalculates the offset so the visible playhead—or pinch start location—remains under the same viewport point. **Fit Timeline** includes the entire duration even at the 30-minute target.

Major tick spacing adapts in integer timeline-frame steps and labels use exact non-drop `HH:MM:SS:FF`. Click/drag scrubbing snaps to gapless clip boundaries within an eight-pixel threshold; holding Option temporarily disables snapping. Timeline thumbnails are requested only when a clip intersects the visible width plus a 260-pixel prefetch margin. A clip with no configured stabilization has no badge; the UI already defines distinct shield and warning shapes with tooltip/accessibility text for valid and stale states, while T16 will replace the current conservative “configured means unvalidated/stale” result with full cache-derived semantics.

`PlaybackCompositionBuilder` constructs an `AVMutableComposition` from the ordered clip array. An unstabilized or stale clip inserts its exact source range. A valid stabilized clip inserts the corresponding range from its cached proxy. An `AVMutableVideoComposition` applies the timeline canvas, aspect-fit transform, black padding, and frame duration. Audio comes from the same source/proxy range and remains linked. Give each clip an isolated audio composition track and combine them with an explicit `AVAudioMix`; the T02 spike found AAC-boundary discontinuities when disjoint clip ranges reused one composition audio track. Track pooling is allowed later only if the parity fixtures remain green.

Structural edits rebuild the in-memory composition; they do not render a full-timeline proxy. Preserve playhead position where possible and rebuild off the main actor, installing the completed player item on `@MainActor`.

The Phase 2 implementation follows that boundary explicitly. `PlaybackCompositionBuilder` runs in a detached user-initiated task, checks cancellation between clips, and returns fully configured composition objects that are treated as immutable. `PlaybackCoordinator` installs the `AVPlayerItem` on the main actor, retains the latest requested frame even when a newer edit supersedes an in-flight build, resumes playback when appropriate, and seeks with zero tolerance during timeline scrubbing. Player time is floored to an exact timeline frame and mapped through `PlaybackSegmentMap` to the logical clip and original source time; the selected-clip inspector exposes that mapping. A `PlaybackMediaSource` override can replace the physical URL/range per clip while logical mapping remains tied to the original project clip, which is the stable integration seam T17 will use for valid stabilized proxies.

The composition uses one non-overlapping video track with one instruction per clip, but one isolated audio track per clip and an explicit `AVAudioMix`. Automated tests recreate the T02 24 fps mixed-format fixture and assert 60 gapless frames, exact cut ranges, canvas/frame duration, three audio tracks, and source-time mapping at every tested boundary. The stabilized-source override is also exercised without changing logical timeline mapping.

The preview is allowed to use the existing 1024-pixel stabilized proxies and bilinear interpolation. Final export always returns to source media and full-quality bicubic stabilization. Automated parity tests must prove that AVFoundation preview timing and FFmpeg output timing agree at every cut.

The T02 parity spike rendered equivalent three-clip compositions through AVFoundation and FFmpeg. The mixed-format 24 fps case produced exactly 60 frames over 2.5 seconds, matching centered padding and 440 Hz → 550 Hz → 440 Hz audio; frame comparison averaged 0.980 SSIM with a 0.935 minimum. A separate 60000/1001 case produced exactly 90 frames over 1.5015 seconds and matching 770 Hz → 440 Hz → 770 Hz audio, averaging 0.987 SSIM with a 0.888 minimum. Encoder/scaler differences prevent byte equality, but every cut and source-frame sequence remained aligned. FFmpeg must receive an explicit rational output rate and `cfr` policy or it can infer the wrong cadence and drop frames. The repeatable validation lives in [`validate-composition-parity.sh`](scripts/spikes/validate-composition-parity.sh) and [the T02 spike record](Tests/Spikes/T02_COMPOSITION_PARITY.md).

### Thumbnail service

Generate original-source thumbnails lazily with `AVAssetImageGenerator`, keyed by asset fingerprint, requested source frame, and display size. Visible timeline regions request thumbnails; off-screen work is cancelled or deprioritized. Deduplicate requests shared by duplicate/split clips. Thumbnail failure shows a neutral placeholder and does not make media unusable.

`ThumbnailRequest` snaps the requested source time to an exact source-frame index before forming its identity. Its cache key contains the asset fingerprint, exact rational source time/frame, pixel width and height, and thumbnail processing revision; it intentionally contains no clip ID or stabilization state. Duplicate clips requesting the same original frame therefore share both in-flight work and the persistent JPEG, while a split/trim that changes the source start requests the correct new frame.

`ThumbnailService` is an actor with one task per project/cache key and a set of visible consumer UUIDs. SwiftUI library and timeline cells live in lazy stacks, which instantiate the visible region plus the framework's small prefetch window. When a cell leaves that region it removes its consumer; generation is cancelled only when no duplicate consumer remains. `AVAssetImageGenerator` runs asynchronously with preferred transform, bounded output size, and zero requested-time tolerance. Cache hits survive reopening, and generation or JPEG failures remain neutral placeholders rather than media errors.

## 8. Undo/redo and autosave

Continue using value semantics. At the target scale, storing prior `ProjectState` values with Swift copy-on-write is simple and cheap enough, provided generated caches and inspected binary objects are outside the state.

`ProjectHistory` contains session-local undo and redo stacks of copy-on-write `ProjectState` values. Each command records one prior state and invalidates redo after a divergent edit. A trim drag has a `TrimTransaction` containing only its original and current candidate source ranges; the persisted/in-memory project value is unchanged until pointer-up applies one validated trim command. Cancel discards the transaction. Project selection and playhead movement are outside both project state and history.

The Phase 2 timeline exposes leading/trailing handles only on the selected clip. Pointer motion is measured in the stable timeline coordinate space, independently of the clip width changing beneath the gesture, and converted by `TimelineTrimMapper` from timeline-frame delta to exact source frames, including mixed-rate and outward non-destructive restoration. The candidate is validated against a temporary value-state editor and drives live gapless ripple layout and inspector values without touching the document session. Clip views use absolute layout positions rather than render-only offsets, so their mutable widths and hit regions remain disjoint. Each clip's drawing frame is fixed before its background, thumbnail clipping, and selection border are rendered; intrinsic filename width therefore cannot escape a short clip's timeline bounds. The selected clip is layered above insertion-boundary drop zones so those invisible targets cannot intercept a trim. Scrubbing begins only on the background/ruler surface and therefore cannot compete with a trim-handle or clip-reorder drag. Pointer-up sends one begin/update/commit transaction to the session; Escape, selection change, or undo during the gesture discards the candidate. No explicit **Confirm Trim** action exists in the project editor.

The frame-aligned playhead enables **Split** only strictly inside the selected clip. Duplicate selects the new adjacent clip, ripple-delete selects the surviving clip at the same ordinal when possible, and both move the playhead to that selection's start. Clip drags use the same visible boundary targets as Media Library drops and translate pre-removal boundary indices correctly when moving forward. Toolbar and **Clip** menu actions share selection/trim/processing enablement; keyboard editing shortcuts remain deferred as planned.

After a committed command or undo/redo, schedule autosave. A failed autosave leaves the last valid file intact and shows a persistent error; it must not erase in-memory edits.

Persistence tests exercise initial save, replacement, Save As identity, close state, injected write failure, rapid debounce, undo/redo autosave, transient versus committed trim, and reopen behavior. The final `.frogmouth` path always decodes as either the previous or new complete state—never a partially written JSON document.

## 9. FFmpeg timeline export

Replace the single-input `VideoPipelinePlan` with a two-level plan:

```swift
struct ClipRenderPlan { /* input, exact range, effects, video/audio normalization */ }
struct TimelineRenderPlan { /* format, ordered clips, concat, metadata, output policy */ }
```

The command factory still produces `Process.arguments`, never a shell string. It may use one input per unique asset and label per-clip filter branches.

For each clip's video branch:

1. Select the exact source range at frame-aligned timestamps.
2. Apply ordered stabilization passes with correctly aligned transforms.
3. Reset timestamps.
4. Normalize frame rate and sample aspect ratio.
5. Aspect-fit scale and centre-pad to the timeline canvas.
6. Normalize pixel format while preserving the approved colour signature.

For audio:

1. Select the linked source range and reset timestamps.
2. Resample and normalize channel layout.
3. Preserve a seamless boundary for adjacent split children that still cover contiguous ranges of the same asset.
4. At unrelated or non-contiguous boundaries, add independent 5–10 ms fade-out/fade-in ramps without overlap.
5. If some clips lack audio, synthesize matching-duration silence; if every clip lacks audio, omit the output audio stream.

Concatenate normalized clip branches in order with a filter graph. Because normalization and anti-click fades are required, multi-clip audio is encoded to high-quality AAC rather than stream-copied. This is a known difference from the single-clip export path.

Continue to use `hevc_videotoolbox`, `hvc1`, fast start, a temporary output, validation, and an atomic final move. Derive the conservative automatic target bitrate from the highest resolution/frame-rate-normalized source bitrate used by the timeline, then apply the existing multiplier/clamp until visual benchmarks justify a better policy.

The T18 implementation expresses this as a pure `TimelineRenderPlanner` followed by `TimelineFFmpegCommandFactory`. Used assets receive one deterministic FFmpeg input in first-timeline-use order; repeated clip uses are fanned out with `split`/`asplit` filter nodes rather than reopening the file. The planner rejects non-frame-aligned source boundaries, records exact source and timeline frame counts, resolves the ordered transform file for every stabilization pass, and carries the total rational duration used by FFmpeg progress. Stabilized video starts at the first pass's full analysis domain, applies each pass with bicubic interpolation, trims into each nested successor domain, and only then slices the final clip range before cadence and canvas normalization.

Audio planning distinguishes contiguous ranges of the same asset from real edit boundaries. Contiguous split children receive no fade; unrelated boundaries receive independent eight-millisecond ramps, shortened when necessary so ramps within a one-frame clip cannot overlap. Every audible branch is retimed to the exact snapped timeline duration, resampled, and conformed to the timeline channel layout. Silent clips receive matching `anullsrc` branches only when another timeline clip has audio; an all-silent timeline produces no audio stream. Snapshot coverage includes raw argument paths containing spaces, Unicode, and apostrophes, repeated inputs, rational 60000/1001 cadence, silent media, and stacked stabilization. The generated-media integration gate renders a 72-frame mixed-rate sequence and verifies its 440 Hz → 550 Hz → silence → 440 Hz regions and 48 kHz stereo timing.

Export always covers the entire timeline. The save panel defaults to the `.frogmouth` directory and a project-derived name such as `Wildlife Morning — Export.mp4`; an untitled project falls back to the first source directory.

### Metadata

- Preserve timeline technical colour/orientation metadata where meaningful.
- Copy a source metadata value only if it is identical and valid across every contributing clip.
- Do not copy the first clip's camera, creation, or GPS metadata as though it described the composition.
- Set container creation time to export time.
- Record the project name and `Encoded by frogmouth`.

Export is disabled while processing is active, media is missing, a timeline clip is invalid, or any stabilization is stale.

## 10. Application components

```text
SwiftUI application shell
├── Startup / project commands
├── Editor layout
│   ├── MediaLibraryView
│   ├── PlayerView
│   ├── ClipInspectorView
│   └── TimelineView
└── ProjectViewModel (@MainActor)
    ├── ProjectDocumentStore (JSON, atomic save, autosave)
    ├── MediaLibraryService (inspect, resolve, validate)
    ├── ProjectHistory / TrimTransaction
    ├── TimelineIndex (derived starts/durations)
    ├── PlaybackCompositionBuilder (AVFoundation)
    ├── ThumbnailService
    ├── StabilizationCoordinator (blocking in first release)
    ├── ProjectCacheStore
    ├── TimelineRenderPlanner / FFmpegCommandFactory
    ├── FFmpegRunner
    ├── ExportCoordinator
    └── DiagnosticLogStore
```

Keep domain and planning types in `FrogmouthCore`, independent of SwiftUI and concrete file processes. Isolate `AVAsset`/`AVPlayerItem` objects in services because they are not project state. Use actors or serial services for file/cache/process work and update observable UI state on `@MainActor`.

Do not add a commercial editing SDK or large timeline framework. Swift, SwiftUI/AppKit, Core Media, AVFoundation, Swift `Codable`, and the existing external FFmpeg installation remain the technology set.

## 11. Diagnostics and failure behavior

Extend diagnostics with project ID/path, schema version, timeline format, media/clip UUIDs, cache keys and hit/miss reasons, exact rational ranges, AV composition rebuilds, normalized FFmpeg render plans, and output metadata decisions. Continue retaining full paths by design for AI-assisted debugging.

User-facing errors must aggregate where useful:

- Project open lists every missing media path in one error and leaves the project unopened.
- Incompatible colour errors name the file and differing properties.
- Stale stabilization names every affected clip and offers selection/update guidance.
- Invalid ranges or changed source files identify the asset and affected clips.
- Save/export failures retain the previous project/final output atomically.

Implemented in T20: diagnostics use sorted, one-line structured events for the project
decision graph. A snapshot records the schema/project identity, timeline format, media facts,
resolved and recorded full paths, clips, exact rational ranges, and stabilization passes.
Separate events capture commands, cache keys and hit/stale reasons, playback-composition
generations, normalized export inputs/filter decisions, metadata provenance, FFmpeg process
outcomes, and atomic finalization. The diagnostics intentionally contain no media bytes.
User-facing failures provide an immediate recovery action and point to Diagnostics → Copy
Diagnostics when further investigation is needed.

## 12. Verification and acceptance criteria

### Unit and schema tests

- Rational-time arithmetic, frame snapping, source/timeline conversion, and long-sequence drift.
- JSON round-trip, deterministic fixtures, unknown fields, unsupported versions, and migrations.
- Path resolution, fingerprint changes, missing-source aggregation, and colour compatibility.
- Derived gapless starts and all clip commands: insert, trim, split, duplicate, reorder, delete.
- One-history-entry trim coalescing, undo/redo branching, and no persisted history.
- Stabilization status/coverage, cache keys, split inheritance, inward trim, outward stale transition, and stacked passes.
- Thumbnail request deduplication and invalidation.
- AV composition segment plans and FFmpeg filter-graph construction.
- Metadata intersection and project/provenance tags.

### Integration tests

- Use short synthetic media fixtures with identifiable frame numbers and audio tones.
- Combine multiple files, repeated ranges from one file, different compatible resolutions/aspect ratios/frame rates, silent clips, and Unicode/space/apostrophe paths.
- Assert exact hard-cut frames, one-frame minimum clips, total duration, audio synchronization, seamless contiguous splits, and anti-click ramps elsewhere.
- Compare AVFoundation preview cut timing with FFmpeg export timing.
- Verify transform inheritance/slicing against a full-range stabilized reference.
- Verify stale stabilization blocks export and explicit update restores it.
- Verify project atomic-save recovery, missing-source open errors, cancellation, and source immutability.
- Inspect output codec, dimensions, rational frame rate, colour signaling, AAC, duration, common metadata, project name, and `Encoded by frogmouth`.

### Performance target

On the target Apple-silicon/macOS environment, a project with 25 imported 4K sources, 50 clips, and a 30-minute timeline must remain responsive after lazy thumbnails are cached. Measure project open, composition rebuild, scroll/zoom, trim feedback, memory, cache size, and export planning separately. Stabilization and export duration remain media-dependent and are not hidden behind UI responsiveness claims.

## 13. Delivery status

The timeline was implemented as incremental vertical slices while the original editor remained available as a parity reference. After project loading, one-clip playback, timeline editing, stabilization, export, diagnostics, and cancellation crossed their acceptance gates, the legacy `EditorViewModel`/`EditState`/`TrimScrubber` architecture and its separate FFmpeg command path were removed in T22. The active app now has one document model and one render architecture.

The dependency-aware task order and per-task acceptance checks are in [TIMELINE_IMPLEMENTATION_TASKS.md](TIMELINE_IMPLEMENTATION_TASKS.md).

## 14. Registered later iterations

- Background, per-clip stabilization job queue that allows editing other clips while processing.
- Recent Projects on the startup screen.
- Comprehensive keyboard editing controls.
- Source preview with in/out selection before timeline insertion.
- Audio waveforms.
- Transitions, which would introduce overlap semantics even with one visible track.
- Selected-range export.
- Custom canvas/output settings.
- Proper SDR/HDR/Log conversion and broader colour management.
- Folder-assisted missing-media search and a Relink UI.
- Exposed stabilization pass stack and per-pass controls.
- Timeline layout/control customization after real use informs it.
