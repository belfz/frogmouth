# frogmouth

<p align="center">
  <img src="Assets/AppIcon.png" alt="frogmouth logo" width="240">
</p>

[![CI](https://github.com/belfz/frogmouth/actions/workflows/ci.yml/badge.svg)](https://github.com/belfz/frogmouth/actions/workflows/ci.yml)

frogmouth is a macOS app for quickly assembling, trimming, splitting, and stabilizing a gapless sequence of video clips, then exporting the complete timeline as a smaller, high-quality HEVC file.

The project was initially designed and developed with Canon EOS R5 footage in mind—primarily 4K H.264 MP4 files with AAC audio. Those videos remain its principal development and testing material, while the application UI is intentionally camera-agnostic. Other formats that FFmpeg can decode are supported on a best-effort basis unless documented otherwise.

The active single-track editor is specified in [TIMELINE_DESIGN.md](TIMELINE_DESIGN.md). Stabilization latency, benchmarks, alternatives, and optimization decisions are tracked in [STABILIZATION_PERFORMANCE.md](STABILIZATION_PERFORMANCE.md).

The first timeline release will preserve the colour characteristics established by its first clip. Clips with conflicting primaries, transfer function (including HDR or Log), matrix, or full/limited range will be rejected with the differing properties listed; frogmouth will not silently convert them. Proper colour conversion is deferred to a later iteration.

Stabilization is intentionally blocking in the first timeline release: analysis and preview rendering show a cancellable progress view, but editing cannot continue until the operation finishes or is cancelled. Background per-clip stabilization is planned for a later iteration. The 25-source/50-clip performance methodology and current measurements are recorded in [Tests/Performance/EDITOR_BENCHMARK.md](Tests/Performance/EDITOR_BENCHMARK.md).

## Using frogmouth

1. Start a new project, create one from video files, or open an existing `.frogmouth` file.
2. Import sources into the Media Library, then append or drag them into the gapless timeline.
3. Select clips to trim, split, duplicate, reorder, delete, stabilize, or add independent picture-only fades to/from black. Trims commit when a handle drag ends; project edits participate in the current session's undo/redo history.
4. Save once to choose a lightweight `.frogmouth` JSON location. Later committed edits autosave there; source files are never modified or embedded.
5. Preview the timeline, then export the complete sequence as a high-quality HEVC MP4. Export defaults to the project directory, or the first used source directory for an unsaved project.
6. If processing or export behaves unexpectedly, use **Diagnostics → Copy Diagnostics** or **Reveal Logs in Finder**.

Project schema `2`, cache-manifest schema `1`, stabilization-processing revision `1`, and thumbnail-processing revision `1` define the current pre-release compatibility boundary. Schema 2 intentionally replaces schema 1 without migration while frogmouth remains pre-release; cache revisions are disposable and rebuild automatically. Details are in [TIMELINE_DESIGN.md](TIMELINE_DESIGN.md#first-timeline-release-compatibility-record).

## Development

Requirements:

- Apple-silicon Mac running macOS 15 or newer
- Xcode 26 / Swift 6
- The tested FFmpeg 7.1.1 build containing `vidstabdetect`, `vidstabtransform`, and `hevc_videotoolbox`

Open `Package.swift` in Xcode and run the `frogmouth` executable scheme, or use:

```sh
swift run frogmouth
```

Build a local, unsigned app bundle with:

```sh
./scripts/build-app.sh
```

The result is `build/frogmouth.app`. Run tests with `swift test`.

Pull requests and pushes to `main` run the complete suite on a macOS 15 Apple-silicon
runner. CI generates and verifies deterministic media fixtures, exercises FFmpeg-backed
integration tests, and builds and validates the unsigned app bundle.

Run the target-scale editor benchmark with:

```sh
scripts/generate-media-fixtures.sh
swift run -c release frogmouth-benchmark
```

frogmouth verifies FFmpeg only at startup. When setup is required, install the documented build and restart the app.

## Future development ideas / to do

- H.264 compatibility export for recipients or older hardware/software that cannot reliably decode HEVC; it needs more bitrate for comparable quality.
- Basic colour controls: exposure, white balance, and contrast while preserving a no-adjustment default.
- A stabilization-strength slider after preset tuning is validated.
- Before/after stabilization comparison.
- Expose and manage the currently implicit ordered stabilization-pass stack, including per-pass controls.
- Process stabilization as background per-clip jobs while editing continues.
- Recent Projects, comprehensive timeline keyboard controls, and user-configurable editor layout.
- A source preview with pre-insert in/out selection, audio waveforms, transitions, and selected-range export.
- Custom timeline canvas settings, proper SDR/HDR/Log conversion, and broader colour management.
- Folder-assisted missing-media search and an in-app Relink workflow.
- Broader, tested format-support tiers beyond Canon-style MP4.
- A maintained supported-FFmpeg list and smoother update guidance.
- Reconsider bundled FFmpeg only if convenience outweighs release size, licensing, update, and signing burden.
- Batch/CLI automation and a macOS sharing workflow.
- Add code signing and notarization before distributing frogmouth outside a local development build.
