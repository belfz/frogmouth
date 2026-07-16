# frogmouth — single-track timeline implementation tasks

This is the ordered execution backlog for [TIMELINE_DESIGN.md](TIMELINE_DESIGN.md). Tasks are deliberately sized as reviewable increments. Check a task only when its acceptance checks pass; do not mark an entire phase complete because its UI appears superficially functional.

## Working rules

- Keep the current single-clip application runnable until the new path reaches one-clip feature parity.
- Put pure domain, timing, persistence, and render-planning logic in `FrogmouthCore`.
- Keep SwiftUI/AppKit, `AVPlayer`, and concrete dialogs in `FrogmouthApp`.
- Build FFmpeg arguments as arrays, never shell strings.
- Use small generated test fixtures for routine integration tests; retain the Canon sample for explicit acceptance tests.
- Add schema fixtures before changing persisted JSON.
- Generated media, transforms, thumbnails, and proxies never enter a `.frogmouth` file.
- Do not implement deferred features while completing these tasks.

## Phase 0 — de-risk the architecture

### T00 — Freeze the current baseline and add reusable media fixtures

Dependencies: none.

- [x] Record the current 14-test baseline and release build command.
- [x] Add a fixture generator for short, frame-numbered videos with distinctive audio tones.
- [x] Generate compatible variants: different dimensions, aspect ratios, rational frame rates, and a silent clip.
- [x] Generate at least one intentionally incompatible colour-signaling fixture.
- [x] Add helpers that inspect exact frame count, duration, audio presence, and colour tags.

Acceptance:

- Fixture generation is deterministic and documented.
- Routine fixtures are small enough for local test runs.
- Existing tests and the release bundle still pass unchanged.

### T01 — Prove stabilization-transform reuse after split/trim

Dependencies: T00.

- [x] Analyze and stabilize a known clip over a parent range.
- [x] Split/trim the range at several frame-aligned points, including 59.94 fps boundaries.
- [x] Prototype slicing and renumbering the ASCII `.trf` rows.
- [x] Compare child renders with the corresponding frames from a full-domain stabilized render.
- [x] Repeat with two stacked stabilization passes.
- [x] Measure the fallback strategy of processing the full analysis domain and trimming afterward.
- [x] Document the chosen algorithm and cache representation in `TIMELINE_DESIGN.md`.

Acceptance:

- The selected approach preserves frame alignment at the first and last child frames.
- Split inheritance requires no new motion analysis.
- The worst-case cost for repeatedly split stabilized clips is understood and accepted.
- If safe transform slicing is impossible, stop and revisit the product decision before implementing stabilization tasks.

### T02 — Prove AVFoundation/FFmpeg composition parity

Dependencies: T00.

- [x] Build a throwaway `AVMutableComposition` from several exact fixture ranges.
- [x] Build the equivalent FFmpeg hard-cut output.
- [x] Cover repeated ranges from one asset and ranges from several assets.
- [x] Conform compatible resolution/aspect-ratio/frame-rate differences to the first clip's format.
- [x] Compare total duration, boundary frames, playhead mapping, and audio timing.
- [x] Verify centre-padding and rational 60000/1001 output behavior.

Acceptance:

- Preview and export identify the same source frame on both sides of every cut.
- Total duration differs by no more than one timeline frame and the reason for any tolerance is documented.
- The conformance rules can be expressed equivalently in AVFoundation and FFmpeg.

### T03 — Define colour compatibility detection

Dependencies: T00.

- [x] Extend inspection facts with primaries, transfer function, matrix, and range.
- [x] Define exact equality/compatibility rules, including missing or unknown tags.
- [x] Test matching SDR fixtures and deliberately conflicting fixtures.
- [x] Specify the actionable error text naming each mismatched property.

Acceptance:

- Compatible sources are not rejected because of spelling/representation differences in metadata.
- HDR/SDR, Log, range, or primary conflicts are rejected rather than silently converted.
- The known trade-off remains documented in the design and user-facing help.

## Phase 1 — exact-time project core

### T04 — Introduce rational media-time primitives

Dependencies: T02.

Suggested types: `MediaTime`, `MediaTimeRange`, `FrameRate`, `TimelineTimeMapper`.

- [x] Implement normalized rational time values with checked arithmetic.
- [x] Bridge to/from `CMTime` without passing through `Double`.
- [x] Implement timeline-frame snapping and source-time mapping with explicit rounding.
- [x] Implement one-frame minimum validation.
- [x] Add formatted `HH:MM:SS:FF` timecode.

Acceptance:

- Long sequences do not accumulate floating-point drift.
- 24, 25, 30, 50, 60, 24000/1001, 30000/1001, and 60000/1001 rates have unit coverage.
- Invalid zero/negative timescales and overflowing arithmetic fail predictably.

### T05 — Add versioned project-domain types and JSON fixtures

Dependencies: T03, T04.

Suggested types: `ProjectState`, `TimelineFormat`, `MediaAsset`, `MediaPathReference`, `MediaFingerprint`, `TimelineClip`, `StabilizationEffect`.

- [x] Implement `Codable`, `Equatable`, `Sendable`, and stable UUID identity.
- [x] Define schema version 1 with deterministic fixture JSON.
- [x] Keep player objects, URLs to cache files, selection, history, and transient state out of the schema.
- [x] Decode unknown fields safely and reject unsupported future schema versions.
- [x] Establish a migration protocol even though version 1 has no predecessor.

Acceptance:

- Encode/decode round trips preserve all project decisions exactly.
- A checked-in JSON fixture remains human-readable and reasonably diffable.
- No generated binary/cache path appears in JSON.

### T06 — Implement the gapless timeline index and edit commands

Dependencies: T04, T05.

Suggested types: `TimelineIndex`, `ProjectHistory`, `TrimTransaction`, `ProjectCommand` or value-state equivalents.

- [x] Derive clip timeline starts from ordered durations.
- [x] Implement insert/append, split, non-destructive trim, duplicate, reorder, ripple-delete, import, and removal of unused media.
- [x] Refuse split at clip edges and removal of referenced media.
- [x] Coalesce a complete trim gesture into one history entry.
- [x] Keep undo/redo session-local and clear redo after divergent edits.
- [x] Derive timeline format from the first inserted clip and retain it if the timeline later becomes empty.

Acceptance:

- Every command and its undo/redo path has unit coverage.
- The timeline remains gapless without storing clip positions.
- Split children cover the exact parent range with neither a missing nor duplicated frame.
- Selection/playhead changes do not create history.

### T07 — Implement media resolution, fingerprinting, and compatibility validation

Dependencies: T03, T05.

Suggested components: `ProjectMediaResolver`, extended `MediaInspector`, `TimelineCompatibilityValidator`.

- [x] Resolve relative paths first and absolute fallbacks second.
- [x] Validate all Media Library entries on project open.
- [x] Aggregate every missing path into one error and leave the project unopened.
- [x] Re-inspect changed fingerprints and validate existing clip ranges.
- [x] Validate colour compatibility on timeline insertion.
- [x] Calculate aspect-fit/pad and frame-rate conformance facts for compatible clips.

Acceptance:

- Project-open validation never partially mutates in-memory state.
- Missing-source errors list all missing files.
- Changed files cannot silently shift or truncate existing edits.
- Compatibility errors name the file and conflicting colour properties.

### T08 — Implement atomic project persistence and autosave

Dependencies: T05, T06, T07.

Suggested components: `ProjectDocumentStore`, `AutosaveCoordinator`.

- [x] Create untitled/new, open, first save, save, and save-as operations.
- [x] Use a sibling temporary file followed by atomic replacement.
- [x] Debounce autosave after committed edits and undo/redo.
- [x] Never write transient trim-drag state.
- [x] Preserve the last valid file and in-memory state after a failed save.
- [x] Prompt on closing an unsaved modified project.
- [x] Reset undo/redo on reopen.

Acceptance:

- Interruption/failure tests never leave a truncated project at the final path.
- Autosave produces valid JSON after rapid edit sequences.
- Reopen reconstructs the exact current project state but no undo history.

### T09 — Add the persistent, disposable project cache

Dependencies: T05, T07.

Suggested components: `ProjectCacheStore`, `CacheManifest`, `CacheKeyBuilder`.

- [x] Create project/asset-keyed cache directories under the app cache root.
- [x] Include source fingerprints and processing revisions in keys.
- [x] Support atomic cache writes, cache-hit validation, and stale-reason reporting.
- [x] Add **Clear Project Cache** and **Clear All Caches** service operations.
- [x] Ensure project loading survives a wholly absent cache.

Acceptance:

- Cache deletion changes derived state, never project JSON.
- Modified sources and incompatible FFmpeg/processing revisions cannot reuse stale artifacts.
- Cache operations never remove user media or project documents.

## Phase 2 — document and timeline UI

### T10 — Replace startup/session lifecycle with a one-project shell

Dependencies: T08.

- [x] Add **New Project** and **Open Project…** startup actions.
- [x] Open dropped `.frogmouth` files.
- [x] Create an untitled project from dropped video files and append them in dropped order.
- [x] Enforce one open project at a time with normal save checks.
- [x] Route standard New/Open/Save/Save As/Close commands.
- [x] Keep FFmpeg startup validation and setup guidance intact.

Acceptance:

- No Recent Projects UI exists yet.
- Replacing a modified project cannot discard changes silently.
- Startup works with no project, an untitled project, and a saved project.

### T11 — Build the modular editor shell and Media Library

Dependencies: T06, T07, T10.

- [x] Add collapsible left library, centre viewer, right inspector, and bottom timeline regions.
- [x] Import one or several sources into the library with progress/error feedback.
- [x] Show thumbnail placeholder, filename, duration, and compact media facts.
- [x] Append or drag a full source into a timeline boundary.
- [x] Allow repeated insertion of one asset.
- [x] Refuse removal while referenced and show the usage count.

Acceptance:

- Library rows have stable identity under import/remove/undo/redo.
- Media insertion order is deterministic.
- No source-preview/in-out editor is accidentally introduced.

### T12 — Implement lazy original-source thumbnail generation

Dependencies: T09, T11.

Suggested component: `ThumbnailService` using `AVAssetImageGenerator`.

- [x] Request thumbnails only for visible timeline/library content plus a small prefetch margin.
- [x] Deduplicate requests across duplicate and split clips.
- [x] Cache by source fingerprint, exact requested frame, and display size.
- [x] Cancel or deprioritize off-screen requests.
- [x] Use neutral placeholders on failure.
- [x] Never regenerate thumbnails merely because stabilization changes.

Acceptance:

- Scrolling does not perform synchronous media decoding on the main actor.
- Split/trim updates sample the correct original-source frames.
- Cache hits survive reopening a project.

### T13 — Build the zoomable, scrollable timeline presentation

Dependencies: T06, T11, T12.

- [x] Map exact timeline time to horizontal coordinates from a pixels-per-second scale.
- [x] Render thumbnail clips, filename labels, selection, boundaries, stabilization icons, and playhead.
- [x] Add horizontal scrolling, zoom slider, pinch-to-zoom, and **Fit Timeline**.
- [x] Preserve the playhead/pointer anchor during zoom.
- [x] Add adaptive timecode ticks and click/drag scrubbing.
- [x] Add snapping with a temporary-disable modifier.
- [x] Use icon shape plus tooltip/accessibility text for stabilization states.

Acceptance:

- Empty, one-frame, short, long, and 50-clip timelines render correctly.
- Zoom does not jump unexpectedly to the left edge.
- Cached scrolling/zooming remains responsive at the target project size.

### T14 — Add direct timeline editing interactions and remove Confirm Trim

Dependencies: T06, T13.

- [x] Select one clip and expose its details in the inspector.
- [x] Add trim handles with live gapless ripple feedback.
- [x] Commit one undo step on pointer-up and restore on cancellation.
- [x] Split selected clip at the frame-aligned playhead.
- [x] Drag to reorder with a clear insertion indicator.
- [x] Duplicate and ripple-delete the selected clip.
- [x] Remove the old explicit **Confirm Trim** workflow from the new editor.
- [x] Wire toolbar/menu enablement to selection and processing state.

Acceptance:

- No pointer-move event creates an undo entry or autosave.
- Every completed structural gesture has correct undo/redo behavior.
- Playback time and selection remain sensible after ripple edits.

### T15 — Build AVFoundation timeline playback

Dependencies: T02, T06, T07, T14.

Suggested components: `PlaybackCompositionBuilder`, `PlaybackCoordinator`.

- [x] Assemble ordered source ranges into an `AVMutableComposition`.
- [x] Apply aspect-fit/pad and timeline frame duration with `AVMutableVideoComposition`.
- [x] Preserve linked audio and hard cuts.
- [x] Rebuild off the main actor and install player items on `@MainActor`.
- [x] Retain playhead position where possible after edits.
- [x] Map player time back to selected clip/source time exactly.
- [x] Preserve a public source-override seam so T17 can substitute valid stabilized proxies without changing composition semantics.

Acceptance:

- Trim/split/reorder becomes visible without rendering a full-timeline proxy.
- Playback crosses all clip boundaries without unintended gaps.
- Preview cut/frame mapping still matches the T02 parity fixtures.

## Phase 3 — clip-scoped stabilization

### T16 — Implement stabilization coverage and status semantics

Dependencies: T01, T06, T09.

- [ ] Persist pass mode/order, analysis coverage, and processing revision but not cache URLs.
- [ ] Derive `none`, `valid`, and `stale(reason:)` from project plus cache state.
- [ ] Preserve complete pass stacks on split and duplicate.
- [ ] Keep inward trims/reorder valid; mark outward extensions stale.
- [ ] Mark missing/purged/incompatible artifacts stale.
- [ ] Block export whenever a timeline-used clip is stale.

Acceptance:

- Status transitions and every invalidation reason have unit tests.
- Project JSON stays valid when the entire cache is deleted.
- A stale clip retains its stabilization configuration.

### T17 — Move stabilization processing to the selected clip

Dependencies: T15, T16.

- [ ] Analyze only the selected clip's current valid pipeline.
- [ ] Preserve multiple ordered passes.
- [ ] Store transforms and the 1024-pixel preview proxy in persistent project cache.
- [ ] Implement explicit **Update Stabilization** for stale clips.
- [ ] Keep the progress modal blocking and cancellable.
- [ ] Preview stale clips from source and valid clips from the correctly mapped proxy range.
- [ ] Reuse valid caches after reopen and undo/redo.

Acceptance:

- No trim starts analysis automatically.
- Split inheritance requires no re-analysis and remains frame-aligned.
- Cancellation leaves the last valid project/cache state intact.
- Audio remains present and synchronized in stabilized preview clips.

## Phase 4 — complete-timeline export

### T18 — Replace the single-input pipeline with timeline render plans

Dependencies: T01, T02, T03, T06, T07, T16.

Suggested types: `ClipRenderPlan`, `TimelineRenderPlan`, `TimelineFFmpegCommandFactory`.

- [ ] Map unique source assets to FFmpeg inputs.
- [ ] Build per-clip video branches for exact range, stabilization, timestamp reset, fps, scale, pad, sample aspect ratio, and pixel format.
- [ ] Build linked audio branches with trim, timestamp reset, resampling, and channel normalization.
- [ ] Preserve continuous audio across contiguous split children.
- [ ] Add 5–10 ms non-overlapping anti-click fades at unrelated/non-contiguous boundaries.
- [ ] Synthesize silence for isolated silent clips when the timeline otherwise has audio.
- [ ] Concatenate normalized branches in timeline order.
- [ ] Calculate conservative timeline bitrate and export progress duration.

Acceptance:

- Argument-array/filter-graph snapshot tests cover spaces, Unicode, apostrophes, repeated assets, silent clips, and stacked stabilization.
- The factory never invokes a shell.
- Integration fixtures produce exact ordered cuts and synchronized audio.

### T19 — Add project-aware export, metadata policy, and validation

Dependencies: T18.

- [ ] Export the entire timeline only.
- [ ] Default to the project directory/name; use first-source directory for untitled projects.
- [ ] Encode HEVC with `hevc_videotoolbox`, `hvc1`, conservative bitrate, and fast start.
- [ ] Encode normalized timeline audio as high-quality AAC.
- [ ] Preserve only common valid source metadata plus timeline technical colour/orientation facts.
- [ ] Set export creation time, project name, and `Encoded by frogmouth`.
- [ ] Write to a temporary output, validate it, and atomically move/replace the final file.
- [ ] Reveal a successful export in Finder and retain manual Reveal Export.

Acceptance:

- Export is disabled for empty/invalid timelines, active processing, missing used media, or stale stabilization.
- Output inspection verifies codec, canvas, rational fps, colour, audio, duration, metadata, and project provenance.
- Cancellation/failure never leaves a misleading final output.

## Phase 5 — hardening and migration

### T20 — Expand diagnostics and actionable errors

Dependencies: T08, T09, T15, T17, T19.

- [ ] Log project/schema IDs, exact ranges, media/clip IDs, cache keys/hits/misses, composition builds, render plans, and metadata decisions.
- [ ] Aggregate missing-source errors.
- [ ] Explain incompatible colour properties.
- [ ] List stale clips and update guidance.
- [ ] Report invalid changed-source ranges without modifying the project.
- [ ] Keep Copy Diagnostics and Reveal Logs useful with full paths.

Acceptance:

- A diagnostics dump is sufficient to reconstruct the project decision graph without containing media bytes.
- Every major failure explains what the user can do next.

### T21 — Meet the performance and accessibility target

Dependencies: T12–T20.

- [ ] Benchmark 25 imported 4K sources, 50 clips, and a 30-minute timeline.
- [ ] Measure open, autosave, composition rebuild, cached/uncached scroll, zoom, trim feedback, memory, and disk cache.
- [ ] Move any remaining media/file work off the main actor.
- [ ] Add accessibility labels/actions for clips, handles, playhead, icons, sidebars, and processing state.
- [ ] Test keyboard focus even though comprehensive shortcuts are deferred.
- [ ] Perform human playback/export acceptance tests on real wildlife footage.

Acceptance:

- Timeline interactions remain responsive after lazy thumbnails are cached.
- No known correctness issue is disguised as a performance optimization.
- Blocking stabilization is explicitly documented as a first-release limitation.

### T22 — Retire the legacy single-clip flow and finish documentation

Dependencies: T21.

- [ ] Prove one-source/one-clip trim, stacked stabilization, preview, export, logs, and cancellation parity.
- [ ] Remove or adapt legacy `EditState`, `TrimRange`, `TrimScrubber`, and one-source `EditorViewModel` code only after parity.
- [ ] Update `TECHNICAL_DESIGN.md` status and route future readers to the timeline design.
- [ ] Update README development/use instructions and the future-work list.
- [ ] Record the JSON schema and cache compatibility revision used by the release.

Acceptance:

- No dead dual architecture remains unintentionally.
- All automated suites, release build, and manual acceptance checks pass.
- The shipped behavior and documentation agree.

## Deferred backlog registered during design

These are intentionally not prerequisites for T00–T22:

- [ ] Background per-clip stabilization queue with continued editing.
- [ ] Recent Projects.
- [ ] Comprehensive timeline keyboard controls.
- [ ] Source preview with pre-insert in/out selection.
- [ ] Audio waveforms.
- [ ] Transitions.
- [ ] Selected-range export.
- [ ] Custom canvas/output settings.
- [ ] SDR/HDR/Log conversion and broader colour management.
- [ ] Folder-assisted missing-media search and Relink UI.
- [ ] Exposed stabilization-pass stack and per-pass controls.
- [ ] User-configurable timeline/editor layout.
