import Foundation

public extension DiagnosticLogStore {
    func appendProjectSnapshot(
        _ project: ProjectState,
        fileURL: URL?,
        resolvedMediaURLs: [MediaAsset.ID: URL],
        phase: String = "project-state"
    ) {
        let sessionID = project.id.uuidString
        var summary = [
            "project_id": project.id.uuidString,
            "schema_version": String(project.schemaVersion),
            "project_name": project.name,
            "project_path": fileURL?.path ?? "<unsaved>",
            "media_count": String(project.mediaLibrary.count),
            "clip_count": String(project.clips.count),
        ]
        if let format = project.timelineFormat {
            summary.merge(format.diagnosticFields) { _, new in new }
        } else {
            summary["timeline_format"] = "<none>"
        }
        append(
            level: "INFO",
            sessionID: sessionID,
            phase: phase,
            event: "project.snapshot",
            fields: summary
        )

        for (index, asset) in project.mediaLibrary.enumerated() {
            append(
                level: "INFO",
                sessionID: sessionID,
                phase: phase,
                event: "project.media",
                fields: [
                    "index": String(index),
                    "asset_id": asset.id.uuidString,
                    "source_path": asset.path.absoluteFallback,
                    "relative_path": asset.path.relativeToProject ?? "<none>",
                    "resolved_path": resolvedMediaURLs[asset.id]?.path ?? "<unresolved>",
                    "file_size": String(asset.fingerprint.fileSize),
                    "modified_ns": String(asset.fingerprint.modificationTimeNanoseconds),
                    "duration": asset.inspected.duration.diagnosticRational,
                    "dimensions": "\(asset.inspected.width)x\(asset.inspected.height)",
                    "frame_rate": asset.inspected.frameRate.diagnosticRational,
                    "video_codec": asset.inspected.videoCodec,
                    "video_bitrate": String(asset.inspected.videoBitrate),
                    "audio_codec": asset.inspected.audioCodec ?? "<none>",
                    "audio_sample_rate": asset.inspected.audioSampleRate.map(String.init) ?? "<none>",
                    "audio_channels": asset.inspected.audioChannelCount.map(String.init) ?? "<none>",
                    "colour": asset.inspected.colour.diagnosticDescription,
                ]
            )
        }

        for (index, clip) in project.clips.enumerated() {
            append(
                level: "INFO",
                sessionID: sessionID,
                phase: phase,
                event: "project.clip",
                fields: [
                    "index": String(index),
                    "clip_id": clip.id.uuidString,
                    "asset_id": clip.assetID.uuidString,
                    "source_range": clip.sourceRange.diagnosticDescription,
                    "stabilization_pass_count": String(clip.stabilizationPasses.count),
                    "video_fade_in_ms": clip.videoFadeIn.map {
                        String($0.durationMilliseconds)
                    } ?? "<none>",
                    "video_fade_out_ms": clip.videoFadeOut.map {
                        String($0.durationMilliseconds)
                    } ?? "<none>",
                ]
            )
            for (passIndex, effect) in clip.stabilizationPasses.enumerated() {
                append(
                    level: "INFO",
                    sessionID: sessionID,
                    phase: phase,
                    event: "project.stabilization-pass",
                    fields: [
                        "clip_id": clip.id.uuidString,
                        "pass_index": String(passIndex),
                        "effect_id": effect.id.uuidString,
                        "mode": effect.mode.rawValue,
                        "analysis_range": effect.analysisCoverage.diagnosticDescription,
                        "processing_revision": String(effect.processingRevision),
                    ]
                )
            }
        }
    }

    func appendTimelineRenderPlan(
        _ plan: TimelineRenderPlan,
        destinationURL: URL,
        sessionID: String
    ) {
        append(
            level: "INFO",
            sessionID: sessionID,
            phase: "timeline-export",
            event: "render-plan.summary",
            fields: [
                "project_id": plan.projectID.uuidString,
                "destination_path": destinationURL.path,
                "input_count": String(plan.inputs.count),
                "clip_count": String(plan.clips.count),
                "total_frames": String(plan.totalFrames),
                "total_duration": plan.totalDuration.diagnosticRational,
                "has_audio": String(plan.hasAudio),
                "target_video_bitrate": String(plan.targetVideoBitrate),
            ].merging(plan.format.diagnosticFields) { _, new in new }
        )
        for input in plan.inputs {
            append(
                level: "INFO",
                sessionID: sessionID,
                phase: "timeline-export",
                event: "render-plan.input",
                fields: [
                    "input_index": String(input.index),
                    "asset_id": input.assetID.uuidString,
                    "source_path": input.url.path,
                ]
            )
        }
        for (index, clip) in plan.clips.enumerated() {
            append(
                level: "INFO",
                sessionID: sessionID,
                phase: "timeline-export",
                event: "render-plan.clip",
                fields: [
                    "index": String(index),
                    "clip_id": clip.clipID.uuidString,
                    "asset_id": clip.assetID.uuidString,
                    "input_index": String(clip.inputIndex),
                    "source_range": clip.sourceRange.diagnosticDescription,
                    "source_frames": "\(clip.sourceStartFrame)..<\(clip.sourceEndFrame)",
                    "source_frame_rate": clip.sourceFrameRate.diagnosticRational,
                    "timeline_frames": String(clip.timelineFrameCount),
                    "timeline_duration": clip.timelineDuration.diagnosticRational,
                    "source_audio": String(clip.hasSourceAudio),
                    "audio_fade_in": String(clip.audioFadeInDuration),
                    "audio_fade_out": String(clip.audioFadeOutDuration),
                    "video_fade_in_ms": clip.videoFadeIn.map {
                        String($0.durationMilliseconds)
                    } ?? "<none>",
                    "video_fade_out_ms": clip.videoFadeOut.map {
                        String($0.durationMilliseconds)
                    } ?? "<none>",
                    "stabilization_pass_count": String(clip.stabilizationPasses.count),
                ]
            )
            for (passIndex, pass) in clip.stabilizationPasses.enumerated() {
                append(
                    level: "INFO",
                    sessionID: sessionID,
                    phase: "timeline-export",
                    event: "render-plan.stabilization-pass",
                    fields: [
                        "clip_id": clip.clipID.uuidString,
                        "pass_index": String(passIndex),
                        "effect_id": pass.effectID.uuidString,
                        "mode": pass.mode.rawValue,
                        "coverage_frames": "\(pass.coverageStartFrame)..<\(pass.coverageEndFrame)",
                        "transforms_path": pass.transformsURL.path,
                    ]
                )
            }
        }
    }

    func appendTimelineMetadata(
        _ metadata: TimelineExportMetadata,
        sourceMetadata: [[String: String]],
        sessionID: String
    ) {
        append(
            level: "INFO",
            sessionID: sessionID,
            phase: "timeline-export",
            event: "metadata.decision",
            fields: [
                "source_count": String(sourceMetadata.count),
                "source_keys": sourceMetadata
                    .map { $0.keys.sorted().joined(separator: ",") }
                    .joined(separator: " | "),
                "common_source_tags": metadata.commonSourceTags
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ","),
                "output_tags": metadata.ffmpegTags
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ","),
            ]
        )
    }
}

public extension MediaTime {
    var diagnosticRational: String { "\(value)/\(timescale)" }
}

public extension MediaTimeRange {
    var diagnosticDescription: String {
        let endValue = (try? end().diagnosticRational) ?? "<invalid>"
        return "start=\(start.diagnosticRational),duration=\(duration.diagnosticRational),end=\(endValue)"
    }
}

public extension FrameRate {
    var diagnosticRational: String { "\(numerator)/\(denominator)" }
}

public extension VideoColourMetadata {
    var diagnosticDescription: String {
        [
            "primaries=\(Self.describe(primaries))",
            "transfer=\(Self.describe(transferFunction))",
            "matrix=\(Self.describe(matrix))",
            "range=\(Self.describe(range))",
        ].joined(separator: ",")
    }

    private static func describe(_ value: ColourMetadataValue) -> String {
        switch value {
        case .unspecified: "unspecified"
        case let .known(identifier): identifier
        case let .unknown(identifier): "unknown:\(identifier)"
        }
    }
}

public extension ProjectCommand {
    var diagnosticName: String {
        switch self {
        case .importMedia: "import-media"
        case .removeUnusedMedia: "remove-media"
        case .insertClip: "insert-clip"
        case .appendClip: "append-clip"
        case .splitClip: "split-clip"
        case .trimClip: "trim-clip"
        case .duplicateClip: "duplicate-clip"
        case .moveClip: "move-clip"
        case .deleteClip: "delete-clip"
        case .setStabilizationPasses: "set-stabilization-passes"
        case .setVideoFade: "set-video-fade"
        }
    }

    var diagnosticFields: [String: String] {
        switch self {
        case let .importMedia(asset):
            [
                "asset_id": asset.id.uuidString,
                "source_path": asset.path.absoluteFallback,
            ]
        case let .removeUnusedMedia(assetID):
            ["asset_id": assetID.uuidString]
        case let .insertClip(clip, index):
            Self.clipFields(clip).merging(["destination_index": String(index)]) { _, new in new }
        case let .appendClip(clip):
            Self.clipFields(clip)
        case let .splitClip(clipID, offset, rightClipID):
            [
                "clip_id": clipID.uuidString,
                "timeline_frame_offset": String(offset),
                "right_clip_id": rightClipID.uuidString,
            ]
        case let .trimClip(clipID, sourceRange):
            [
                "clip_id": clipID.uuidString,
                "source_range": sourceRange.diagnosticDescription,
            ]
        case let .duplicateClip(clipID, newClipID):
            [
                "clip_id": clipID.uuidString,
                "new_clip_id": newClipID.uuidString,
            ]
        case let .moveClip(clipID, index):
            [
                "clip_id": clipID.uuidString,
                "destination_index": String(index),
            ]
        case let .deleteClip(clipID):
            ["clip_id": clipID.uuidString]
        case let .setStabilizationPasses(clipID, passes):
            [
                "clip_id": clipID.uuidString,
                "pass_count": String(passes.count),
                "effect_ids": passes.map { $0.id.uuidString }.joined(separator: ","),
            ]
        case let .setVideoFade(clipID, edge, fade):
            [
                "clip_id": clipID.uuidString,
                "edge": edge.rawValue,
                "duration_ms": fade.map { String($0.durationMilliseconds) } ?? "<none>",
            ]
        }
    }

    private static func clipFields(_ clip: TimelineClip) -> [String: String] {
        [
            "clip_id": clip.id.uuidString,
            "asset_id": clip.assetID.uuidString,
            "source_range": clip.sourceRange.diagnosticDescription,
            "stabilization_pass_count": String(clip.stabilizationPasses.count),
            "video_fade_in_ms": clip.videoFadeIn.map {
                String($0.durationMilliseconds)
            } ?? "<none>",
            "video_fade_out_ms": clip.videoFadeOut.map {
                String($0.durationMilliseconds)
            } ?? "<none>",
        ]
    }
}

public extension StabilizationStatus {
    var diagnosticName: String {
        switch self {
        case .none: "none"
        case .valid: "valid"
        case .stale: "stale"
        }
    }
}

private extension TimelineFormat {
    var diagnosticFields: [String: String] {
        [
            "timeline_dimensions": "\(width)x\(height)",
            "timeline_frame_rate": frameRate.diagnosticRational,
            "timeline_colour": colour.diagnosticDescription,
            "timeline_audio_sample_rate": String(audioSampleRate),
            "timeline_audio_channels": String(audioChannelCount),
        ]
    }
}
