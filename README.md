# frogmouth

frogmouth is a personal macOS app for quickly stabilizing and trimming wildlife videos, then exporting a smaller, high-quality HEVC file.

The project was initially designed and developed with Canon EOS R5 footage in mind—primarily 4K H.264 MP4 files with AAC audio. Those videos remain its principal development and testing material, while the application UI is intentionally camera-agnostic. Other formats that FFmpeg can decode are supported on a best-effort basis unless documented otherwise.

The implementation design is in [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md). Stabilization latency, benchmarks, alternatives, and optimization decisions are tracked in [STABILIZATION_PERFORMANCE.md](STABILIZATION_PERFORMANCE.md).

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

frogmouth verifies FFmpeg only at startup. When setup is required, install the documented build and restart the app.

## Future development ideas / to do

- H.264 compatibility export for recipients or older hardware/software that cannot reliably decode HEVC; it needs more bitrate for comparable quality.
- Multiple clips: trim several clips and assemble them into one output.
- Basic colour controls: exposure, white balance, and contrast while preserving a no-adjustment default.
- A stabilization-strength slider after preset tuning is validated.
- Before/after comparison, a thumbnail filmstrip, and finer trim controls.
- Expose and manage the currently implicit ordered edit-operation stack.
- Broader, tested format-support tiers beyond Canon-style MP4.
- A maintained supported-FFmpeg list and smoother update guidance.
- Reconsider bundled FFmpeg only if convenience outweighs release size, licensing, update, and signing burden.
- Project persistence, batch/CLI automation, and a macOS sharing workflow.
- Add code signing and notarization before distributing frogmouth outside a local development build.
