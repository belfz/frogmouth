# Changelog

All notable user-facing changes to frogmouth are documented here. The project
uses product-oriented [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-07-24

### Added

- A gapless, single-track editor with multiple imported source files and clips.
- Frame-precise trimming, splitting, duplication, reordering, deletion, and
  session undo/redo.
- Per-clip Steady and Natural Motion stabilization with reusable analysis
  artifacts.
- Independent picture-only fade-in from black and fade-out to black controls.
- Timeline preview with linked audio and whole-timeline HEVC export.
- Lightweight `.frogmouth` JSON projects with autosave and missing-source
  diagnostics.
- Media Library thumbnails, timeline zoom, source inspection, structured logs,
  and export recovery diagnostics.

### Changed

- Project schema 2 is the stable 1.0 compatibility baseline. Future schema
  changes must provide explicit migration from released project formats.
- FFmpeg 7.1.1 and 8.1.2 are the tested external tool versions for the 1.0
  release.

[Unreleased]: https://github.com/belfz/frogmouth/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/belfz/frogmouth/releases/tag/v1.0.0
