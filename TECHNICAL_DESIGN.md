# frogmouth — technical design (v1)

## 1. Purpose and scope

frogmouth is a lightweight, personal macOS video editor for wildlife footage. It edits one Canon EOS R5-style MP4 clip at a time:

- repeatedly trim and confirm the current working range;
- add one or more stabilization passes using two fixed presets;
- preview the selected stabilized result before export; and
- export a smaller, visually comparable HEVC/H.265 MP4 while retaining the source resolution, frame rate, audio, and compatible metadata.

The source file is never altered. There are no saved projects: closing or replacing the input discards the current edit session and temporary render files.

### Target environment

- Apple-silicon Macs (M1 or newer)
- macOS 15 Sequoia or newer
- Direct distribution, initially as a local Xcode build
- Not sandboxed and not App Store-targeted in v1
- GPL-compatible source/distribution is acceptable

### Tested input

`EOS R5 example video.MP4` is the first acceptance sample. Its inspected profile is:

| Property | Value |
| --- | --- |
| Video | AVC/H.264 (`avc1`), 4096×2160, 24 fps, ~120 Mb/s |
| Audio | AAC, 48 kHz, stereo, ~253 kb/s |
| Colour | Rec.709, full range |
| Duration / size | 9.292 s / ~133 MB |

Canon-style MP4 is the supported and tested input class. Other files FFmpeg can decode may be accepted as best effort, but are not v1 compatibility commitments.

### Explicitly out of scope for v1

- multiple clips, joins, transitions, or timelines;
- colour correction/grading;
- audio editing;
- stabilization strength controls;
- before/after split or toggle preview;
- thumbnail filmstrips;
- H.264 export;
- batch processing, command-line operation, or project files;
- signed/notarized distribution.

## 2. Technology decisions

### Application: Swift 6, SwiftUI, AVFoundation

Implement frogmouth as a native Swift 6 macOS app with SwiftUI. AVFoundation supplies media inspection and playback (`AVURLAsset`, `AVPlayer`), while SwiftUI provides the small one-window interface, standard menus, dialogs, accessibility, and keyboard shortcuts.

Rust is deliberately **not** part of v1. It would be a good fit for a portable media-processing engine, but frogmouth owns no such engine: FFmpeg performs the expensive work. Adding Rust would introduce FFI/build complexity without improving the rendering path. Swift is also the most useful language to learn for a macOS-only product and has direct, ergonomic access to Apple media APIs.

Keep application logic independent from view code. SwiftUI views render an observable `EditorViewModel`; command construction and process management live behind protocols so they are unit-testable without rendering UI.

### Render engine: external FFmpeg with libvidstab

frogmouth is a UI and orchestration layer over a separately installed FFmpeg executable. It must not bundle FFmpeg in v1. This keeps the app light and lets the user update the processing engine independently.

Stabilization requires both `vidstabdetect` and `vidstabtransform`, which FFmpeg exposes only when compiled with `--enable-libvidstab`. The first filter writes per-frame transforms and the second applies them. The documented `hevc_videotoolbox` encoder uses Apple VideoToolbox hardware acceleration. [FFmpeg filter documentation](https://ffmpeg.org/ffmpeg-filters.html)

The stock Homebrew `ffmpeg` formula must not be assumed sufficient: its current listed dependencies do not include `libvidstab`. The setup screen will point to a project-approved Homebrew tap/build recipe, then validate the installed executable rather than infer capability from its name. [Homebrew FFmpeg formula](https://formulae.brew.sh/formula/ffmpeg.html)

#### FFmpeg compatibility contract

The app stores a small, versioned `SupportedFFmpeg` policy in code (later replaceable with a maintained list):

- accepted executable paths: the configured path, then common Apple Silicon Homebrew locations;
- the explicitly approved FFmpeg 7.1.1 build (expand this list only after testing);
- `ffmpeg -version` must succeed;
- `ffmpeg -filters` must list `vidstabdetect` and `vidstabtransform`;
- `ffmpeg -encoders` must list `hevc_videotoolbox`; and
- a cheap capability smoke test must run before enabling an edit session.

At startup, `FFmpegLocator` validates the executable. If unavailable or incompatible, frogmouth shows a simple setup screen with the documented install command and a statement that the app must be restarted after installation. The exact tap and version are a release artifact: do not hard-code an untested third-party tap in source without testing it on Sequoia/Apple Silicon.

## 3. User experience

### States

```text
FFmpeg setup required ── install/restart ──> Empty editor
Empty editor ── choose/drop video ──> Editing original
Editing ── adjust handles / Confirm Trim ──> Rebased editing range
Editing ── Apply Steady/Natural Motion ──> Analyzing
Analyzing ── proxy ready / commit pass ──> Editing stabilized preview
Editing or preview ── Export… ──> Exporting (modal, cancellable)
Exporting ── success/failure/cancel ──> Editing stabilized preview
```

### Editing window

- Open via an **Open Video** button and support Finder drag-and-drop. If a clip is already loaded, confirm that the user wants to discard the current session before accepting a replacement; the source file is never changed.
- Show filename, source resolution, frame rate, duration, and source size.
- Use an `AVPlayer` preview.
- Use a simple labeled time scrubber: start handle, end handle, and a vertical playhead. No thumbnails. Handle motion creates a pending trim.
- **Confirm Trim** commits the pending range as one undoable operation, rebases it to the full scrubber width, and resets its time labels to `00:00…duration`. This can be repeated.
- Supply play/pause (Space) and conventional time labels. Approximate QuickTime-style scrubbing is sufficient.
- Offer two commit actions: **Apply Steady** for stronger smoothing and **Apply Natural Motion** for lighter smoothing that preserves tracking pans. Applying either action adds a pass on top of existing edits; repeated and mixed passes are allowed.
- Disable stabilization and export while a trim remains unconfirmed.
- Keep the ordered edit stack implicit in v1. Show only the current pipeline result; a stabilized preview is rendered through every committed operation, not simulated.
- Display one export choice: **High-quality HEVC — original resolution and frame rate — smaller file**. It includes brief explanatory text that frogmouth chooses the encoding parameters automatically.
- **Export…** always opens a normal macOS save dialog; never overwrite or generate a sibling file automatically.

### Analysis, preview, export, and cancellation

Changing trim handles affects only the pending range. Confirming it appends a trim operation and preserves every earlier stabilization pass. It may require re-rendering the proxy, but never re-analyzes stabilization automatically. Applying a stabilization action analyzes only the current committed pipeline output and commits the new pass after its preview succeeds.

Analysis and export each show a focused modal progress view with phase text, determinate progress when parseable, an indeterminate fallback, and **Cancel**. Editing is disabled while a process runs. Cancellation terminates the FFmpeg process group, waits for termination, removes only frogmouth-owned temporary files, and returns to the last valid editor state.

### Undo/redo

Keep an in-memory, current-clip-only command stack:

- confirmed trim operations, including the pre-confirmation handle range;
- committed stabilization passes.

Expose menu/toolbar actions and `⌘Z` / `⇧⌘Z`. A handle drag is not history by itself; **Confirm Trim** records the whole range as one command. Undoing that command restores the previous working range and handle positions. Undoing a stabilization removes only the latest pass; redo reuses its retained transform cache. Selecting a different input asks for confirmation before beginning a new session and clearing history.

## 4. Processing design

### Session files

Create a unique directory inside `FileManager.default.temporaryDirectory`, for example:

```text
frogmouth/<UUID>/
  transforms-<pass UUID>.trf
  preview-<render UUID>.mp4
  ffmpeg-analysis.log
  ffmpeg-preview.log
  ffmpeg-export.log
```

Never place temporary files beside the source. Remove the directory on normal close/replacement/cancel; retain enough diagnostic logs after a failure to copy diagnostics, then delete on the next app launch according to a bounded retention policy.

### Analysis pass

Run `vidstabdetect` after every previously committed trim/stabilization filter, so it sees exactly the current pipeline output. Each pass owns a distinct transform file. A later trim retains earlier transform files and is inserted after their filters; a later stabilization therefore analyzes the already-stabilized, newly trimmed result.

Illustrative argument structure (construct an argument array; never invoke a shell):

```text
ffmpeg -hide_banner -nostdin -y
  -ss <collapsed-leading-trim-start> -i <source>
  -map 0:v:0 -an
  -vf <prior operation filters>,vidstabdetect=result=<session/transforms-pass.trf>:shakiness=<...>:accuracy=<...>:stepsize=<...>:fileformat=ascii
  -t <current-pipeline-duration>
  -f null -
```

Leading trims before the first stabilization are collapsed into input-side seeking. Trims after a stabilization remain ordered `trim,setpts` filters so earlier motion transforms keep their original frame alignment. The same `VideoPipelinePlan` constructs analysis, preview, and export. FFmpeg 7.1.1's binary transform writer produced files that its transform reader rejected during integration testing, so v1 deliberately uses the larger but interoperable ASCII representation.

Fixed profile constants are centralized in `StabilizationProfile`, not scattered through strings:

| Profile | `shakiness` | `accuracy` | `stepsize` | `smoothing` | Intent |
| --- | ---: | ---: | ---: | ---: | --- |
| Steady | 8 | 9 | 12 | 30 | Strong handheld smoothing |
| Natural motion | 5 | 9 | 12 | 8 | Keep more pan/tracking motion |

These are initial benchmark values, not a user-facing contract. On the supplied 4K sample, `accuracy=9:stepsize=12` makes detection practical while preserving a detailed motion search; the prior maximum-accuracy defaults were several times slower. `smoothing=30` deliberately produces much more smoothing than `8`; FFmpeg documents that higher smoothing limits pan/tilt acceleration. Tune them against more real wildlife footage before release. Both render profiles set adaptive crop/zoom (`optzoom=2`) so borders do not appear. There is no crop warning in v1; frogmouth always applies the chosen profile. [FFmpeg vidstab options](https://ffmpeg.org/ffmpeg-filters.html)

### Stabilized preview proxy

After analysis, render an HEVC proxy through the complete ordered operation list. Scale only this temporary preview to an aspect-preserving width of 1024 pixels. The final export is never downscaled and never uses the lossy proxy as an input.

Use `AVPlayer` to play the proxy. Keep the original asset/player available while no stabilization is selected. The preview proxy intentionally omits audio if that materially improves responsiveness; the final export always retains audio unchanged. If audio is retained in the proxy, it must be copied rather than re-encoded.

### Final export

The final FFmpeg invocation composes all committed trims and stabilization transforms in order, maps video and optional audio, and writes an MP4. If a trim occurs after stabilization, use a separately sought audio input so copied AAC remains aligned with the final absolute source range. The output must retain:

- exact source encoded dimensions and nominal frame rate (e.g. 4096×2160 at 24 fps);
- source colour signaling, without grading, conversion, or tone mapping;
- original AAC audio stream unchanged and synchronized (`-c:a copy` where compatible); and
- compatible container metadata (`-map_metadata 0` plus targeted validation).

Video must be HEVC via `hevc_videotoolbox`. Select the hardware encoder explicitly; fail with a helpful message rather than silently falling back to a slower/different software codec.

The automatic high-quality policy is intentionally conservative:

```text
targetVideoBitrateMbps = clamp(round(sourceVideoBitrateMbps × 0.60), 35, 80)
```

For the supplied ~120 Mb/s source, this starts at 72 Mb/s: a meaningful but not aggressive size reduction. Make the clamp and multiplier named constants and validate them with visual comparisons. Do not expose bitrate/quality controls in v1.

An illustrative render filter is:

```text
vidstabtransform=input=<transforms.trf>:smoothing=<profile>:optzoom=2:interpol=bicubic
```

The exact command must be captured in diagnostics and tested with paths containing spaces, Unicode, and apostrophes. Use `Process.executableURL` plus `Process.arguments`; never create a shell command string. A production command also needs explicit stream mapping, MP4-compatible HEVC tagging when required, fast-start handling, timestamps, metadata, and a temporary output path followed by an atomic move only after successful completion.

### Metadata policy

Preserve source container metadata wherever FFmpeg can safely map it. Validation must confirm expected creation/camera/location tags and record any tags FFmpeg cannot retain across H.264-to-HEVC MP4 export. Do not promise preservation of codec-private metadata without an automated sample test.

## 5. Application architecture

```text
SwiftUI views
  └─ EditorViewModel (@MainActor state machine)
      ├─ MediaInspector (AVFoundation)
      ├─ EditSession / UndoManager
      ├─ PreviewCoordinator (AVPlayer + temporary proxy)
      ├─ FFmpegLocator / CapabilityValidator
      ├─ FFmpegCommandFactory
      ├─ FFmpegRunner (Process, stdout/stderr, cancellation, progress)
      ├─ ExportCoordinator
      └─ DiagnosticLogStore
```

Suggested domain types:

```swift
struct MediaInfo: Sendable { /* URL, video/audio streams, dimensions, fps, duration, bitrate, metadata */ }
struct TrimRange: Equatable, Sendable { let start: TimeInterval; let end: TimeInterval }
enum StabilizationMode: String, CaseIterable, Sendable { case steady, naturalMotion }
enum EditOperation: Equatable, Sendable { case trim(TrimRange); case stabilization(StabilizationPass) }
struct EditState: Equatable, Sendable { let sourceDuration: TimeInterval; var operations: [EditOperation]; var pendingTrim: TrimRange }
enum ProcessingPhase: Equatable { case idle, analyzing, renderingPreview, exporting, failed(FrogmouthError) }
```

Use Swift concurrency for orchestration, but isolate `Process` I/O behind an actor or serial service. UI changes happen on `@MainActor`; all FFmpeg output parsing and file I/O happen off the main actor. Depend on protocols such as `FFmpegExecuting`, `MediaInspecting`, and `Clock` to enable deterministic tests.

## 6. Diagnostics and error handling

Write structured local logs with ISO-8601 timestamp, level, session ID, and phase. Retain full source/destination paths by design. Include:

- frogmouth version/build, macOS version, hardware architecture;
- discovered FFmpeg path, full version/configuration, and capability-check result;
- normalized media facts and edit state;
- argument-array rendering (quoted only for display), process identifier, exit status, duration;
- FFmpeg stderr/progress and redacted environment; and
- errors, cancellation, output validation, and cleanup outcome.

Provide **Copy Diagnostics** (clipboard-ready plain text) and **Reveal Logs in Finder**. Logs never copy video samples or media bytes. Do not log unrelated environment variables or credentials.

User-facing errors must state what failed and what to do next: unsupported FFmpeg, unreadable/corrupt source, unsupported stream, insufficient disk space, cancelled processing, unavailable VideoToolbox HEVC encoder, failed metadata validation, or output write failure. Preserve the source and do not leave a partially named final output; partial files remain temporary and are cleaned up.

## 7. Verification and acceptance criteria

### Automated tests

- unit-test profile/command construction, range validation, quality policy, state transitions, undo coalescing, FFmpeg-version parsing, and log redaction policy;
- integration-test capability validation against the approved FFmpeg build;
- integration-test analysis, proxy, cancellation, and export using the supplied R5 sample;
- test paths containing spaces, Unicode, apostrophes, a missing audio stream, and an unwritable output location;
- assert source hash and modification date never change;
- inspect output with AVFoundation/FFprobe-equivalent assertions: HEVC video, original dimensions/fps, AAC stream when input has audio, duration within one frame/one audio packet of trim, and expected metadata; and
- assert temporary files are removed after success/cancel and prior session state survives a failed export.

### Human acceptance tests

- In full-screen 4K viewing, exported footage is visually indistinguishable from the source apart from the intentional stabilization crop.
- **Steady** clearly reduces static handheld shake; **Natural motion** retains visibly more intentional tracking/pan movement.
- No black/held borders appear from stabilization.
- The stabilized preview depicts the actual selected result before export.
- The R5 sample exports at the same 4096×2160/24 fps, preserves colour appearance and audio, is smaller than the original, and opens in QuickTime Player.
- Cancel is prompt, safe, and leaves no final output.
- Diagnostics are sufficient to paste directly into an AI-assisted debugging session.

## 8. Implementation sequence

1. Create a minimal Xcode SwiftUI app and local README; establish lint/test formatting.
2. Implement FFmpeg setup screen, approved-build documentation, locator, and capability validation.
3. Implement media inspection, source preview, and basic one-clip session lifecycle.
4. Add the scrubber, confirm/rebase trim workflow, ordered edit state, and undo/redo.
5. Build FFmpeg process/logging infrastructure and cancellation before adding the actual filters.
6. Implement analysis plus temporary transform lifecycle; benchmark the two profiles on the R5 sample and real wildlife clips.
7. Render/play stabilized proxy and correctly invalidate it on edit changes.
8. Implement save-panel export, hardware HEVC policy, audio/metadata mapping, output validation, and atomic finalization.
9. Complete error UX, Copy Diagnostics, automated tests, and manual visual acceptance tests.

## 9. Deferred work

The project roadmap and distribution to-do list live in the [README](README.md), keeping this document focused on the v1 implementation contract.
