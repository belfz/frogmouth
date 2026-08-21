<!-- memory-backup:start -->
# Project Memory

_Last refreshed: 2026-08-21 22:55 CEST_

## Recovery snapshot

- Frogmouth is a native macOS video editor for Marcin's wildlife footage. It began as a QuickTime-like Canon EOS R5 clip tool and is now a lightweight, project-based, gapless single-track sequence editor.
- The released baseline is `v1.0.0`. `main` is clean at `1b9bd31` (`Add interactive Frogmouth codebase field guide (#10)`) before this memory file is added. GitHub release `v1.0.0` is public and current.
- The app supports multiple source files and timeline clips, frame-precise trim/split/reorder/duplicate/delete, linked audio, per-clip stacked stabilization, picture-only fades, AVFoundation preview, and whole-timeline HEVC export through external FFmpeg.
- There is no active feature or open GitHub issue as of this refresh. The safest next action is to choose one item from `README.md` under **Future development ideas / to do**, create a GitHub issue, work on a dedicated branch, run the full suite, and open a PR for Marcin's manual review.
- Treat this file as a recovery aid. Verify mutable facts against the current repository, GitHub, and installed toolchain before changing code.

## Coverage and confidence

- Reviewed the only accessible project-scoped Codex task, **Design macOS video editor**, covering 192 turns from initial design through implementation, release 1.0, and the codebase field guide.
- Reviewed current `main`, recent and phase history, `README.md`, `TIMELINE_DESIGN.md`, `STABILIZATION_PERFORMANCE.md`, `CHANGELOG.md`, `RELEASING.md`, `Package.swift`, source/test/script inventories, CI/release workflows, and the field-guide documentation.
- Verified GitHub on 2026-08-21: there were no open issues; release `v1.0.0` was public, non-draft, non-prerelease, and had DMG, ZIP, and checksum assets.
- No previous `MEMORY.md` existed. No manual notes required preservation.
- No other project-scoped tasks were returned by the app. Projectless and unrelated chats were not imported. Confidence is high for repository state and durable product decisions; future roadmap priorities remain intentionally undecided.
- English is the substantive project language, so this recovery brief uses English only.

## Goals and success criteria

- Provide fast, understandable editing for wildlife videos on Apple-silicon Macs running macOS 15 or newer.
- Keep the editor simpler than a general NLE: one sequential, gapless track; hard cuts; permanently linked source audio; no multi-track ambition.
- Preserve source files. Store only edit decisions and media references in lightweight `.frogmouth` JSON projects.
- Preserve source colour characteristics and metadata where compatible. Reject incompatible colour combinations instead of silently converting them.
- Export the complete timeline as a smaller, visually high-quality HEVC MP4 with automatic settings and useful provenance metadata.
- Make failures diagnosable: persistent structured logs must be easy to copy into an AI debugging session.
- Keep the GUI native and macOS-specific. Heavy media processing belongs to AVFoundation or the independently installed FFmpeg executable, not a custom Rust engine.

## Current state

### Completed and released

- `v1.0.0`, released 2026-07-24 from tag `v1.0.0`.
- Apple-silicon, macOS 15+ SwiftUI application built with Swift 6 / Swift Package Manager.
- One `.frogmouth` project open at a time; JSON schema 2 is the first stable compatibility baseline.
- Media Library with up to the designed target of 25 imported sources; one source can back many clips.
- Gapless single-track timeline designed for up to 50 clips / 30 minutes.
- Frame-exact timeline math, trim, split at playhead, append/insert, duplicate, reorder, and ripple-delete.
- Session-only undo/redo for committed edits. Trim drag is one transaction and commits when the pointer is released; there is no **Confirm Trim** button in the sequence editor.
- Keyboard shortcuts include `C` to split the selected clip at the playhead and Backspace/Delete to remove it, plus normal macOS document/history commands.
- AVFoundation whole-timeline preview with linked audio.
- Selected-clip **Steady** and **Natural Motion** stabilization; repeated passes stack in order. Processing is blocking but cancellable. Analysis/proxy artifacts are cached and can become stale for explainable reasons.
- Independent per-clip picture-only fade-in and fade-out from black, stored in milliseconds. Defaults use up to 1000 ms; combined durations cannot exceed clip duration. Preview and FFmpeg export match.
- Whole-timeline HEVC/AAC export with automatic quality policy, compatible metadata/provenance, hidden partial output, validation, and atomic finalization.
- Export bitrate scales to output resolution; this fixed oversized exports from low-bitrate Full-HD MOV sources.
- Export dialog starts in the project directory, or the first used source directory for an unsaved project. Completed files remain visible in Finder.
- Structured diagnostics, cache diagnostics, missing-source/stale-stabilization errors, and recovery instructions.
- Native app/logo assets and camera-neutral UI copy. README records that Canon EOS R5 4K H.264/AAC material initialized the project.
- macOS GitHub Actions CI for PRs and pushes to `main`; tagged release workflow builds unsigned DMG/ZIP/checksums and creates a draft release.
- Dependency-free interactive codebase guide at `docs/codebase-field-guide/index.html`, including architecture, runtime flows, operation/file effects, tests, configuration, and review guidance.

### Repository state at backup

- Branch: `main`, tracking `origin/main`.
- Revision before adding this file: `1b9bd31`.
- Working tree was clean before backup. `MEMORY.md` becomes a new untracked file after this refresh.
- No open GitHub issues were found on 2026-08-21.
- No implementation is in progress or blocked.

## Architecture and important files

### Package boundaries

- `Package.swift`: Swift tools 6.2, macOS 15 minimum, no third-party Swift packages.
- `Sources/FrogmouthCore/`: testable domain and media/service implementation.
- `Sources/FrogmouthApp/`: SwiftUI/AppKit application, composition root, document coordinator, editor views, and playback coordinator.
- `Sources/FrogmouthBenchmark/`: target-scale editor benchmark.
- `Tests/FrogmouthCoreTests/`: Swift Testing unit, contract, persistence, integration, and real-media tests.

### Core mental model

- The architecture is **command-driven domain core + actor-isolated services + `@MainActor` application coordinator + declarative SwiftUI views**.
- `ProjectState` is value state. `ProjectCommand` and `ProjectEditor` in `Sources/FrogmouthCore/TimelineEditing.swift` are the validated entry point for durable edits.
- Frogmouth is **not command-sourced**: commands are not persisted or replayed. `.frogmouth` stores the latest project state. `ProjectHistory` stores project snapshots only for the current session.
- Swift actors such as `ProjectDocumentSession`, `ProjectCacheStore`, `ProjectAutosaveCoordinator`, and `ThumbnailService` serialize mutable state and filesystem work. They are local concurrency primitives, not an Akka-style actor system; actor methods can be reentrant across `await`.
- Exact rational time is central. `Sources/FrogmouthCore/ExactTime.swift`, `TimelineIndex`, and mapping helpers avoid using floating-point seconds for edit decisions.

### Main code paths

- App/menu/root: `FrogmouthApp.swift`, `ApplicationViewModel.swift`, `RootView.swift`.
- Main UI coordinator: `ProjectDocumentViewModel.swift` (`@MainActor`).
- Editor layout and inspector: `ProjectEditorShell.swift`.
- Timeline geometry and interaction: `SequenceTimelineView.swift`, `TimelinePresentation.swift`, `TimelineTrimming.swift`.
- Project model/editing/persistence: `ProjectDomain.swift`, `TimelineEditing.swift`, `ProjectPersistence.swift`, `ProjectMedia.swift`.
- Preview: `PlaybackCoordinator.swift`, `PlaybackComposition.swift`, `NativeVideoPlayer.swift`.
- Stabilization: `ClipStabilizationProcessor.swift`, `ClipStabilizationCommandFactory.swift`, `StabilizationPassPlanner.swift`, `StabilizationStatus.swift`, `ProjectCache.swift`.
- Export: `TimelineRenderPlan.swift` -> `TimelineFFmpegCommandFactory.swift` -> `FFmpegRunner.swift` -> `TimelineExport.swift`.
- Import/inspection/compatibility: `MediaInspector.swift`, `ColourCompatibility.swift`, `QualityPolicy.swift`.
- Diagnostics and temporary workspace: `DiagnosticLogStore.swift`, `ProjectDiagnostics.swift`, `SessionWorkspace.swift`.
- Architecture guide: `docs/codebase-field-guide/`. Update it in the same PR when ownership, persisted state, runtime/file flows, integrations, tests, or development commands change. Prefer stable responsibilities over line counts.

### State and filesystem behavior

- Source media is read-only and is never embedded in a project.
- `.frogmouth` contains sources, fingerprints/facts, timeline format, ordered clips, source ranges, stabilization descriptors, and video fades.
- Selection, playhead, zoom, busy/progress state, trim preview, players, and undo/redo stacks are session-only.
- Split, trim, reorder, delete, duplicate, and fades are metadata/state edits; they do not render new media.
- Stabilization uses temporary processing files and durable disposable cache artifacts; only complete artifacts enter the cache.
- Export writes a hidden partial sibling, validates output and provenance, then atomically publishes the final file.

## Decisions and rationale

- 2026-07-12 — Use Swift 6, SwiftUI, AVFoundation, and external FFmpeg; no Rust layer. Rationale: Frogmouth is a native macOS UI/orchestrator while FFmpeg does heavy processing. **Implemented/current.**
- 2026-07-12 — Target Apple silicon and macOS Sequoia/macOS 15+. Rationale: narrow native platform target and hardware HEVC support. **Implemented/current.**
- 2026-07-12 — Require a tested, user-installed FFmpeg rather than bundle it. Rationale: keep Frogmouth lightweight and decoupled from FFmpeg releases. Restart is required after installation/change because verification occurs at startup. **Implemented/current.**
- 2026-07-12 — Default to high-quality HEVC, preserve dimensions/frame rate/colour, use automatic crop/zoom for stabilization, and retain audio. Rationale: substantially smaller files with comparable visible quality on modern Macs. **Implemented/current.**
- 2026-07-12 — Provide fixed **Steady** and **Natural Motion** stabilization profiles; no strength slider yet. **Implemented; slider deferred.**
- 2026-07-12 — Keep the app GUI-only but make diagnostics detailed and AI-friendly, including full file paths. **Implemented/current.**
- 2026-07-13 — Preview stabilization uses bilinear interpolation; final export retains bicubic. Rationale: improve preview speed without reducing final quality. **Implemented/current.** See `STABILIZATION_PERFORMANCE.md` for measurements and alternatives.
- 2026-07-16 to 2026-07-21 — Replace the single-clip/session-only editor with a project-based, one-track gapless sequence editor. Rationale: support many sources and clips without adopting multi-track NLE complexity. **Implemented; legacy editor removed.**
- 2026-07 — Multiple tracks are outside the expected product direction, not merely a near-term omission. Audio stays linked; boundaries are hard cuts; gaps are disallowed. **Current product boundary.**
- 2026-07 — Project paths use relative-to-project when practical plus absolute fallback; project open fails with one actionable list of all missing sources. No in-app relink in 1.0. **Implemented; relink deferred.**
- 2026-07 — Stabilization is selected-clip and processing blocks editing. Background jobs were judged too complex for the first sequence release. **Implemented; background processing deferred.**
- 2026-07-21 — Export bitrate must be derived from output format/resolution, not blindly preserve a 4K floor for smaller MOV timelines. **Implemented and manually confirmed.**
- 2026-07-23 — Fades affect picture only; audio fades are separate future work. Each edge is independent, durations use integer milliseconds, ramps are linear, preview/export agree, and fades apply after stabilization/conformance. **Implemented/current.**
- 2026-07-24 — Project schema 2 is the first released compatibility contract. No migration from unreleased schema 1 was required, but all future released schemas must decode or explicitly migrate schema 2. **Current release contract.**
- 2026-07-24 — Use product-oriented Semantic Versioning, `VERSION` as user-facing source of truth, annotated `vX.Y.Z` tags, draft release automation, and manual publish after verification. **Implemented/current.**
- 2026-07-24 — Release 1.0 unsigned and unnotarized. Rationale: the user does not want to pay for Apple Developer Program membership yet and accepts Gatekeeper friction. **Current distribution trade-off; revisit before broader commercial distribution.**
- 2026-07 to 2026-08 — Documentation should be a concrete tutorial, not marketing material. Remove decorative metrics/line counts; retain meaningful hotspot markers. **Applied to the field guide.**

## Work history and conversation map

- 2026-07-12 — Product/technology grill and initial implementation. Created native single-clip Frogmouth with trim, stabilization, preview/export, logs, and Git repository.
- 2026-07-13 — Added branding, camera-neutral UI copy, preserved preview audio/export behavior, and reduced preview stabilization rendering cost.
- 2026-07-16 to 2026-07-21 — Implemented phases 0–5 of the sequence-editor redesign: fixtures/de-risking, exact-time project core, document/UI/timeline, clip stabilization, complete export, diagnostics/performance/accessibility, and legacy removal. PR #1 merged.
- 2026-07-21 to 2026-07-22 — Diagnosed oversized MOV exports using real user projects; fixed resolution-aware bitrate policy. Issue #2 / PR #3 merged and manually confirmed.
- 2026-07-22 to 2026-07-23 — Added macOS GitHub Actions CI. PR #4 merged.
- 2026-07-23 to 2026-07-24 — Designed and implemented independent per-clip picture fades. Issue #5 / PR #6 merged and manually confirmed.
- 2026-07-24 — Added release/version/changelog workflow, unsigned packaging, update link, and compatibility policy. Issue #7 / PR #9 merged.
- 2026-07-24 — Tagged, built, independently verified, and published Frogmouth `v1.0.0` with DMG, ZIP, and SHA-256 manifest.
- 2026-07-24 to 2026-08-04 — Added and refined the interactive codebase field guide; clarified actors and command-driven-vs-command-sourced architecture; removed marketing-style copy and volatile metrics. Issue #8 / PR #10 merged.

## Constraints, conventions, and preferences

- The user is an experienced TypeScript/full-stack programmer with some Rust and limited Swift/SwiftUI experience. Explain Swift/macOS concepts in relation to familiar ideas when helpful, but keep the code native.
- Ask one question at a time during design grills. Offer a recommendation and explain the trade-off.
- Work iteratively with visible review gates. For substantial features, the preferred cycle is GitHub issue -> dedicated branch -> implementation and tests -> PR -> user manual verification -> user merge.
- Do not merge a PR or begin a later phase without explicit approval. Respect any task-specific request to leave changes uncommitted for review.
- Use concise, concrete technical language. Avoid catchy headings, promotional copy, decorative statistics, and badges that do not teach something.
- Preserve user changes and avoid destructive Git operations. The user normally pushes/merges after review unless explicitly asking the agent to do it.
- Keep the UI camera-agnostic. Canon EOS R5 footage is the primary development target; other FFmpeg-decodable formats are best-effort.
- Preserve source colour; no grading controls in 1.0. Reject incompatible colour metadata rather than silently convert.
- GPL use is acceptable to the user. Commercial sale is not prohibited by FFmpeg licensing, but Mac App Store distribution remains problematic with the current external executable/GPL/tooling model and unsigned distribution.

## Commands and validation

### Local development

```sh
swift run frogmouth
swift test
./scripts/build-app.sh
./scripts/verify-app-bundle.sh
./scripts/package-release.sh
```

- Open `Package.swift` in Xcode and run the `frogmouth` executable scheme for the best SwiftUI editing/debugging experience.
- Local unsigned app output: `build/frogmouth.app`.
- Release artifacts: `build/releases/`.
- `VERSION` supplies `CFBundleShortVersionString`; `FROGMOUTH_BUILD_NUMBER` can override the default commit-count build number.

### Fixtures and performance

```sh
./scripts/generate-media-fixtures.sh
./scripts/verify-media-fixtures.sh
swift run -c release frogmouth-benchmark
```

- `Tests/Fixtures/ProjectSchemaV2.frogmouth` is the canonical schema contract.
- `Tests/Performance/EDITOR_BENCHMARK.md` records target-scale methodology/results.
- Last known full local validation: `swift test` passed 110 tests during PR #10 validation on 2026-08-04. It was not rerun solely for this memory refresh.
- CI runs deterministic fixture verification, FFmpeg-backed integration tests, the Swift suite, app build verification, and packaging on macOS 15 Apple silicon.
- Release workflow for `vX.Y.Z` tags creates an unsigned draft GitHub Release. Follow `RELEASING.md`; publish only after manual artifact verification.

### Codebase guide

```sh
python3 -m http.server 8000
```

Then open `http://localhost:8000/docs/codebase-field-guide/`. The guide is dependency-free static HTML/CSS/JS.

## External dependencies and environment

- macOS 15+ on Apple silicon.
- Xcode 26 / Swift 6; package manifest currently declares Swift tools 6.2.
- Externally installed FFmpeg version 7.1.1 or 8.1.2 with `vidstabdetect`, `vidstabtransform`, and `hevc_videotoolbox`. The app verifies the exact executable/capabilities at startup.
- CI installs `ffmpeg-full` and currently requires FFmpeg 8.1.2 for media integration tests.
- GitHub repository: `belfz/frogmouth`; remote is SSH `origin`.
- GitHub Actions is the CI/release service. No application secrets or environment-variable values are recorded here.
- Distribution is through GitHub Releases. Current artifacts are unsigned and unnotarized; first launch requires macOS Privacy & Security approval.

## Open questions, risks, and known issues

- There are no open GitHub issues as of 2026-08-21. The following are roadmap candidates, not active commitments.
- Stabilization remains slow and blocking for long/high-resolution clips. Current optimizations improved it, but `STABILIZATION_PERFORMANCE.md` retains alternatives such as detection-profile tuning, downscaled analysis/transform scaling, and further interpolation evaluation.
- Current supported-format confidence is strongest for Canon-style 4K H.264/AAC MP4 and tested trail-camera MOV material. Broader formats are best-effort.
- Proper SDR/HDR/Log conversion and broader colour management are not implemented.
- External FFmpeg keeps the app small and independently updatable, but complicates installation, licensing/distribution review, App Store eligibility, and reproducibility.
- Unsigned/unnotarized releases create Gatekeeper friction and are unsuitable for broad commercial distribution. Developer ID signing/notarization requires paid Apple Developer Program membership.
- The field guide can drift. Any architectural or workflow PR must review and update it when affected.

### Deferred feature ideas

- H.264 compatibility export for older recipients/devices.
- Basic exposure, white-balance, and contrast controls.
- Stabilization strength slider, before/after comparison, and explicit stabilization-pass-stack management.
- Background per-clip stabilization while editing continues.
- Recent Projects, broader keyboard controls, and configurable layout.
- Source preview/in-out selection, audio waveforms, transitions, selected-range export, and audio fades.
- Custom canvas/output settings and proper colour conversion.
- Folder-assisted missing-media search and in-app relink.
- Broader tested format tiers and supported-FFmpeg registry/guidance.
- Batch/CLI automation and macOS sharing workflow.
- Developer ID signing and notarization.

## Recommended next steps

1. Confirm `main`, Git status, `VERSION`, open GitHub issues, and the latest release before starting new work.
2. Choose one roadmap item with Marcin; use the grill-me flow if behavior or scope is not already precise.
3. Create a GitHub issue with acceptance criteria and implementation proposal, then create a dedicated `codex/` branch unless Marcin requests another name.
4. Implement through the established domain/service boundaries. Keep durable edits as validated commands and update schema/cache revisions only when their compatibility meaning changes.
5. Add focused unit/contract tests first and real-media integration evidence when preview, FFmpeg, audio, colour, or output semantics change.
6. Update `CHANGELOG.md` under `Unreleased` for user-visible changes and update the codebase guide when architecture/workflow facts change.
7. Run the full suite and relevant app/fixture checks. Open a PR and wait for Marcin's manual acceptance and merge.

## Handoff prompt

Resume Frogmouth from current `main`. First read `README.md`, `TIMELINE_DESIGN.md`, this memory, and the relevant chapter in `docs/codebase-field-guide/`; then verify Git/GitHub state and current tests. Preserve the one-track, exact-time, command-driven architecture and ask Marcin which roadmap item should become the next issue before implementing anything new.
<!-- memory-backup:end -->
