# T22 — single-clip parity and legacy retirement

The timeline architecture is the only shipped editing path. This record maps every capability
from the retired session-only editor to active automated evidence before its types, UI, and
FFmpeg command factory were deleted.

| Capability | Active architecture | Automated evidence |
| --- | --- | --- |
| One source / one clip | `ProjectState` with one `MediaAsset` and one `TimelineClip` | `importingAndInsertingClipsDerivesAndRetainsTimelineFormat`, project fixture/open tests |
| Precise repeated trim and undo/redo | Exact `MediaTimeRange`, `TimelineTrimMapper`, and project commands | `trimGestureIsOneUndoableCommitAndNeverPublishesTransientRanges`, `inwardTrimSplitDuplicateAndReorderRetainValidStabilizationCoverage` |
| Ordered stabilization passes | Persisted `StabilizationEffect` stack and clip-scoped processor | `clipStabilizationCommandsPreserveOrderedNestedPassDomainsAndAudio`, `selectedClipProcessorPersistsBothArtifactsAndReusesThemOnTheNextRun` |
| Preview with audio | AV composition plus validated audio-linked stabilization proxy | `playbackCompositionUsesHardCutsCanvasRateAndIsolatedAudioTracks`, `playbackSourceOverrideDoesNotChangeLogicalTimelineMapping`, `installedFFmpegCanAnalyzeAndRenderAClipScopedAudioLinkedProxy` |
| Verified HEVC export | Timeline render plan, FFmpeg graph, metadata policy, atomic validation/install | `timelineFFmpegSnapshotCoversSpecialPathsRepeatedAssetsSilenceAndStackedPasses`, `verificationExporterRendersValidatesAndInstallsCompleteTimeline` |
| Diagnostics | Project snapshots, normalized render decisions, cache and command events | `diagnosticsCaptureTheProjectDecisionGraphWithExactRanges`, `renderAndMetadataDiagnosticsDescribeNormalizedDecisions`, `asynchronousDiagnosticReadFlushesQueuedWrites` |
| Cancellation and cleanup | Cancellable processor/export tasks with atomic project/cache/output boundaries | `cancellingSelectedClipProcessingDoesNotCommitPartialCacheArtifacts`, `failedAndCancelledTimelineExportsPreserveExistingDestinationAndCleanTemporaryFiles` |

The retired implementation comprised `EditorViewModel`, `TrimScrubber`, `TrimRange`,
`EditState`, `EditHistory`, `EditOperation`, `StabilizationPass`, and the single-input
`FFmpegCommandFactory`. None remains in the production or test source tree. Shared services
such as media inspection, FFmpeg discovery/running, quality policy, session workspaces,
stabilization profiles, processing phases, and the native player remain because the timeline
architecture actively uses them.

## Manual acceptance after removal

Completed successfully on 20 July 2026:

1. Created a project from one source, trimmed it, exercised undo/redo, and confirmed preview timing.
2. Applied both stabilization presets in sequence, confirmed preview audio remained present, and
   cancelled one processing attempt without changing the committed project.
3. Saved/reopened the project, exported it, and inspected picture, audio, duration, colour, and
   metadata.
4. Exercised Copy Diagnostics and Reveal Logs in Finder.

This focused smoke test complements the broader multi-clip acceptance already completed for
T19–T21.
