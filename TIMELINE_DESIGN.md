# frogmouth — single-track timeline design

Status: proposed implementation plan following the July 2026 design interview.

This document describes the planned evolution from frogmouth's current single-clip, session-only editor into a lightweight, project-based editor with one gapless sequence of clips. The existing [v1 technical design](TECHNICAL_DESIGN.md) remains the contract for the currently implemented application. The ordered execution backlog is in [TIMELINE_IMPLEMENTATION_TASKS.md](TIMELINE_IMPLEMENTATION_TASKS.md).

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
    var frameRateNumerator: Int
    var frameRateDenominator: Int
    var colour: ColourSignature
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

All structural edits snap to timeline frame boundaries. When a source frame rate differs, one shared conversion policy maps timeline time to the closest valid source/media time using documented `CMTime` rounding. A clip must contain at least one timeline frame. Split is disabled on either edge.

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
        "modificationTime": "2026-07-14T10:00:00Z"
      },
      "inspected": {
        "duration": { "value": 22155, "timescale": 1000 },
        "width": 4096,
        "height": 2160,
        "frameRateNumerator": 60000,
        "frameRateDenominator": 1001
      }
    }
  ],
  "timelineFormat": {
    "width": 4096,
    "height": 2160,
    "frameRateNumerator": 60000,
    "frameRateDenominator": 1001,
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
        "start": { "value": 0, "timescale": 60000 },
        "duration": { "value": 600000, "timescale": 60000 }
      },
      "stabilizationPasses": []
    }
  ]
}
```

The exact schema must be fixture-tested before release. Unknown future fields should be ignored where safe; a newer unsupported `schemaVersion` must produce an actionable error rather than a partial load. Each schema change requires an explicit migration and before/after fixture.

### Paths and missing sources

Store a path relative to the project when practical, plus an absolute fallback and inexpensive identity facts. On open, resolve and validate every Media Library entry. If any file is absent, keep the project unopened and show one error listing every missing path. The user restores the files externally and retries. There is no offline placeholder or Relink UI initially.

If a file exists but its fingerprint changed, re-inspect it. Accept it only if existing clip ranges and compatibility constraints remain valid; otherwise report the conflict without modifying the project.

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

## 5. Media compatibility and conformance

The first timeline clip establishes the output canvas, frame rate, colour signature, and baseline audio format.

For compatible colour sources with different dimensions, aspect ratios, or frame rates:

- Preserve aspect ratio.
- Scale to fit within the timeline canvas.
- Centre-pad unused area with black.
- Convert to the timeline frame rate.
- Normalize sample aspect ratio and timestamps.
- Resample audio and conform channel layout for concatenation.

### Known colour-management trade-off

The first timeline release intentionally rejects sources whose colour characteristics are incompatible with the first clip. Resolution and frame-rate normalization are mechanical; silent HDR/SDR, Log, transfer-function, matrix, range, or primaries conversion could visibly damage footage.

`ColourSignature` must therefore include at least primaries, transfer function, matrix, and full/limited range. Import into the Media Library may succeed, but insertion into an established timeline must explain the exact incompatibility. Proper colour management and explicit conversion controls are deferred. This is a known assumption, not an accidental unsupported case.

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
  thumbnails/<asset fingerprint>/<request key>.jpg
  stabilization/<cache key>/pass-<pass UUID>.trf
  stabilization/<cache key>/preview.mp4
  manifests/<cache key>.json
```

A stabilization cache key includes the asset fingerprint, analyzed source range, ordered preceding pass configuration, current pass profile, frogmouth processing revision, FFmpeg/libvidstab version, and proxy settings. Cache deletion never corrupts a project; it changes configured stabilization to stale. Provide **Clear Project Cache** and **Clear All Caches**.

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

`PlaybackCompositionBuilder` constructs an `AVMutableComposition` from the ordered clip array. An unstabilized or stale clip inserts its exact source range. A valid stabilized clip inserts the corresponding range from its cached proxy. An `AVMutableVideoComposition` applies the timeline canvas, aspect-fit transform, black padding, and frame duration. Audio comes from the same source/proxy range and remains linked. Give each clip an isolated audio composition track and combine them with an explicit `AVAudioMix`; the T02 spike found AAC-boundary discontinuities when disjoint clip ranges reused one composition audio track. Track pooling is allowed later only if the parity fixtures remain green.

Structural edits rebuild the in-memory composition; they do not render a full-timeline proxy. Preserve playhead position where possible and rebuild off the main actor, installing the completed player item on `@MainActor`.

The preview is allowed to use the existing 1024-pixel stabilized proxies and bilinear interpolation. Final export always returns to source media and full-quality bicubic stabilization. Automated parity tests must prove that AVFoundation preview timing and FFmpeg output timing agree at every cut.

The T02 parity spike rendered equivalent three-clip compositions through AVFoundation and FFmpeg. The mixed-format 24 fps case produced exactly 60 frames over 2.5 seconds, matching centered padding and 440 Hz → 550 Hz → 440 Hz audio; frame comparison averaged 0.980 SSIM with a 0.935 minimum. A separate 60000/1001 case produced exactly 90 frames over 1.5015 seconds and matching 770 Hz → 440 Hz → 770 Hz audio, averaging 0.987 SSIM with a 0.888 minimum. Encoder/scaler differences prevent byte equality, but every cut and source-frame sequence remained aligned. FFmpeg must receive an explicit rational output rate and `cfr` policy or it can infer the wrong cadence and drop frames. The repeatable validation lives in [`validate-composition-parity.sh`](scripts/spikes/validate-composition-parity.sh) and [the T02 spike record](Tests/Spikes/T02_COMPOSITION_PARITY.md).

### Thumbnail service

Generate original-source thumbnails lazily with `AVAssetImageGenerator`, keyed by asset fingerprint, requested source frame, and display size. Visible timeline regions request thumbnails; off-screen work is cancelled or deprioritized. Deduplicate requests shared by duplicate/split clips. Thumbnail failure shows a neutral placeholder and does not make media unusable.

## 8. Undo/redo and autosave

Continue using value semantics. At the target scale, storing prior `ProjectState` values with Swift copy-on-write is simple and cheap enough, provided generated caches and inspected binary objects are outside the state.

`ProjectHistory` contains session-local `past` and `future` stacks. Each command records one before/after state and invalidates `future` after a divergent edit. A trim drag has a `TrimTransaction` containing its starting state and current transient range; only pointer-up records history. Project selection and playhead movement do not.

After a committed command or undo/redo, schedule autosave. A failed autosave leaves the last valid file intact and shows a persistent error; it must not erase in-memory edits.

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

## 13. Delivery strategy

Implement this as incremental vertical slices, not a big-bang replacement. Add exact-time and project-domain types beside the current single-clip model; preserve a green build and the usable v1 editor until project loading, one-clip playback, timeline editing, stabilization, and export have each crossed their acceptance gate. Remove the legacy `EditState`/`TrimScrubber` flow only after the new single-clip path has parity.

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
