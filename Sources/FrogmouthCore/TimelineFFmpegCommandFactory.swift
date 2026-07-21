import Foundation

public enum TimelineRenderEncoding: Equatable, Sendable {
    /// Shipping encoder policy used by the validated, atomic timeline exporter.
    case delivery
    /// Deterministic, software-only codecs used by media-fixture integration tests.
    case verification
}

public enum TimelineFFmpegCommandError: LocalizedError, Equatable, Sendable {
    case emptyRenderPlan
    case invalidCanvas(width: Int, height: Int)
    case invalidAudioFormat(sampleRate: Int, channels: Int)
    case unsupportedStabilizationMode(StabilizationEffect.ID)

    public var errorDescription: String? {
        switch self {
        case .emptyRenderPlan:
            "The timeline render plan contains no clips."
        case let .invalidCanvas(width, height):
            "The timeline canvas \(width)×\(height) is invalid."
        case let .invalidAudioFormat(sampleRate, channels):
            "The timeline audio format \(sampleRate) Hz / \(channels) channels is invalid."
        case let .unsupportedStabilizationMode(effectID):
            "Stabilization pass \(effectID.uuidString) has no render profile."
        }
    }
}

public enum TimelineFFmpegCommandFactory {
    public static func arguments(
        for plan: TimelineRenderPlan,
        output: URL,
        encoding: TimelineRenderEncoding = .delivery,
        metadata: TimelineExportMetadata? = nil
    ) throws -> [String] {
        guard !plan.clips.isEmpty else { throw TimelineFFmpegCommandError.emptyRenderPlan }
        guard plan.format.width > 0, plan.format.height > 0 else {
            throw TimelineFFmpegCommandError.invalidCanvas(
                width: plan.format.width,
                height: plan.format.height
            )
        }
        if plan.hasAudio {
            guard plan.format.audioSampleRate > 0,
                  plan.format.audioChannelCount > 0 else {
                throw TimelineFFmpegCommandError.invalidAudioFormat(
                    sampleRate: plan.format.audioSampleRate,
                    channels: plan.format.audioChannelCount
                )
            }
        }

        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-nostats",
            "-progress", "pipe:1",
        ]
        for input in plan.inputs.sorted(by: { $0.index < $1.index }) {
            arguments += ["-i", input.url.path]
        }

        let graph = try filterGraph(for: plan)
        arguments += [
            "-y",
            "-filter_complex", graph,
            "-map", "[vout]",
        ]
        if plan.hasAudio { arguments += ["-map", "[aout]"] }
        arguments += [
            "-r", rate(plan.format.frameRate),
            "-fps_mode", "cfr",
        ]
        arguments += colourArguments(plan.format.colour)
        arguments += ["-metadata:s:v:0", "rotate=0"]

        switch encoding {
        case .delivery:
            arguments += [
                "-c:v", "hevc_videotoolbox",
                "-b:v", String(plan.targetVideoBitrate),
                "-tag:v", "hvc1",
            ]
            if plan.hasAudio {
                arguments += ["-c:a", "aac", "-b:a", "256k"]
            }
            arguments += ["-movflags", "+faststart"]
        case .verification:
            arguments += [
                "-c:v", "prores_ks",
                "-profile:v", "2",
                "-pix_fmt", "yuv422p10le",
            ]
            if plan.hasAudio { arguments += ["-c:a", "pcm_s16le"] }
        }
        if let metadata {
            arguments += ["-map_metadata", "-1"]
            for (key, value) in metadata.ffmpegTags.sorted(by: { $0.key < $1.key }) {
                arguments += ["-metadata", "\(key)=\(value)"]
            }
        }
        arguments.append(output.path)
        return arguments
    }

    public static func filterGraph(for plan: TimelineRenderPlan) throws -> String {
        var branches: [String] = []
        var concatInputs: [String] = []
        let videoSources = splitSources(
            clips: plan.clips,
            include: { _ in true },
            mediaSuffix: "v",
            labelPrefix: "vsrc",
            branches: &branches
        )
        let audioSources = splitSources(
            clips: plan.clips,
            include: \.hasSourceAudio,
            mediaSuffix: "a",
            labelPrefix: "asrc",
            branches: &branches
        )

        for (index, clip) in plan.clips.enumerated() {
            branches.append(try videoBranch(
                clip,
                index: index,
                format: plan.format,
                sourceLabel: videoSources[index]!
            ))
            concatInputs.append("[v\(index)]")
            if plan.hasAudio {
                branches.append(audioBranch(
                    clip,
                    index: index,
                    format: plan.format,
                    sourceLabel: audioSources[index]
                ))
                concatInputs.append("[a\(index)]")
            }
        }

        let concat = concatInputs.joined()
            + "concat=n=\(plan.clips.count):v=1:a=\(plan.hasAudio ? 1 : 0)"
            + (plan.hasAudio ? "[vout][aout]" : "[vout]")
        branches.append(concat)
        return branches.joined(separator: ";")
    }

    private static func videoBranch(
        _ clip: ClipRenderPlan,
        index: Int,
        format: TimelineFormat,
        sourceLabel: String
    ) throws -> String {
        var filters: [String] = []

        if let firstPass = clip.stabilizationPasses.first {
            filters += [
                "trim=start_frame=\(firstPass.coverageStartFrame):end_frame=\(firstPass.coverageEndFrame)",
                "setpts=PTS-STARTPTS",
            ]
            var currentStart = firstPass.coverageStartFrame
            var currentEnd = firstPass.coverageEndFrame

            for (passIndex, pass) in clip.stabilizationPasses.enumerated() {
                guard let profile = StabilizationProfile.profile(for: pass.mode) else {
                    throw TimelineFFmpegCommandError.unsupportedStabilizationMode(pass.effectID)
                }
                filters.append(
                    "vidstabtransform=input=\(escapedFilterPath(pass.transformsURL)):smoothing=\(profile.smoothing):optzoom=2:interpol=bicubic"
                )
                let nextStart: Int64
                let nextEnd: Int64
                if clip.stabilizationPasses.indices.contains(passIndex + 1) {
                    let next = clip.stabilizationPasses[passIndex + 1]
                    nextStart = next.coverageStartFrame
                    nextEnd = next.coverageEndFrame
                } else {
                    nextStart = clip.sourceStartFrame
                    nextEnd = clip.sourceEndFrame
                }
                if nextStart != currentStart || nextEnd != currentEnd {
                    filters += [
                        "trim=start_frame=\(nextStart - currentStart):end_frame=\(nextEnd - currentStart)",
                        "setpts=PTS-STARTPTS",
                    ]
                }
                currentStart = nextStart
                currentEnd = nextEnd
            }
        } else {
            filters += [
                "trim=start_frame=\(clip.sourceStartFrame):end_frame=\(clip.sourceEndFrame)",
                "setpts=PTS-STARTPTS",
            ]
        }

        let outputRate = rate(format.frameRate)
        filters += [
            "fps=fps=\(outputRate):round=near",
            "trim=end_frame=\(clip.timelineFrameCount)",
            "setpts=N*\(format.frameRate.denominator)/(\(format.frameRate.numerator)*TB)",
            "scale=\(format.width):\(format.height):force_original_aspect_ratio=decrease:flags=lanczos",
            "pad=\(format.width):\(format.height):(ow-iw)/2:(oh-ih)/2:color=black",
            "setsar=1",
            "format=yuv420p",
        ]
        return sourceLabel + filters.joined(separator: ",") + "[v\(index)]"
    }

    private static func audioBranch(
        _ clip: ClipRenderPlan,
        index: Int,
        format: TimelineFormat,
        sourceLabel: String?
    ) -> String {
        let duration = seconds(clip.timelineDuration)
        var filters: [String]
        let prefix: String

        if clip.hasSourceAudio {
            let sourceStart = seconds(clip.sourceRange.start)
            let sourceEnd = seconds((try? clip.sourceRange.end()) ?? clip.sourceRange.start)
            let sourceDuration = seconds(clip.sourceRange.duration)
            prefix = sourceLabel ?? "[\(clip.inputIndex):a]"
            filters = [
                "atrim=start=\(time(sourceStart)):end=\(time(sourceEnd))",
                "asetpts=PTS-STARTPTS",
            ]
            let tempo = duration > 0 ? sourceDuration / duration : 1
            if abs(tempo - 1) > 0.000_001 {
                filters += tempoFilters(tempo)
            }
            filters += [
                "aresample=\(format.audioSampleRate)",
                "aformat=sample_rates=\(format.audioSampleRate):channel_layouts=\(channelLayout(format.audioChannelCount))",
                "apad=whole_dur=\(time(duration))",
                "atrim=duration=\(time(duration))",
            ]
        } else {
            prefix = ""
            filters = [
                "anullsrc=r=\(format.audioSampleRate):cl=\(channelLayout(format.audioChannelCount))",
                "atrim=duration=\(time(duration))",
                "asetpts=PTS-STARTPTS",
            ]
        }

        if clip.audioFadeInDuration > 0, clip.hasSourceAudio {
            filters.append(
                "afade=t=in:st=0:d=\(time(clip.audioFadeInDuration))"
            )
        }
        if clip.audioFadeOutDuration > 0, clip.hasSourceAudio {
            let start = max(0, duration - clip.audioFadeOutDuration)
            filters.append(
                "afade=t=out:st=\(time(start)):d=\(time(clip.audioFadeOutDuration))"
            )
        }
        return prefix + filters.joined(separator: ",") + "[a\(index)]"
    }

    private static func splitSources(
        clips: [ClipRenderPlan],
        include: (ClipRenderPlan) -> Bool,
        mediaSuffix: String,
        labelPrefix: String,
        branches: inout [String]
    ) -> [Int: String] {
        var clipIndicesByInput: [Int: [Int]] = [:]
        for (clipIndex, clip) in clips.enumerated() where include(clip) {
            clipIndicesByInput[clip.inputIndex, default: []].append(clipIndex)
        }
        var labels: [Int: String] = [:]
        for inputIndex in clipIndicesByInput.keys.sorted() {
            let clipIndices = clipIndicesByInput[inputIndex]!
            if clipIndices.count == 1 {
                labels[clipIndices[0]] = "[\(inputIndex):\(mediaSuffix)]"
                continue
            }
            let outputLabels = clipIndices.enumerated().map { ordinal, clipIndex in
                let label = "[\(labelPrefix)\(inputIndex)_\(ordinal)]"
                labels[clipIndex] = label
                return label
            }.joined()
            branches.append(
                "[\(inputIndex):\(mediaSuffix)]\(mediaSuffix == "v" ? "split" : "asplit")=\(clipIndices.count)\(outputLabels)"
            )
        }
        return labels
    }

    private static func tempoFilters(_ requested: Double) -> [String] {
        guard requested.isFinite, requested > 0 else { return [] }
        var remaining = requested
        var factors: [Double] = []
        while remaining > 2 {
            factors.append(2)
            remaining /= 2
        }
        while remaining < 0.5 {
            factors.append(0.5)
            remaining /= 0.5
        }
        if abs(remaining - 1) > 0.000_001 { factors.append(remaining) }
        return factors.map { "atempo=\(time($0))" }
    }

    private static func colourArguments(_ colour: VideoColourMetadata) -> [String] {
        var arguments: [String] = []
        if let value = ffmpegColourValue(colour.primaries, property: .primaries) {
            arguments += ["-color_primaries", value]
        }
        if let value = ffmpegColourValue(colour.transferFunction, property: .transferFunction) {
            arguments += ["-color_trc", value]
        }
        if let value = ffmpegColourValue(colour.matrix, property: .matrix) {
            arguments += ["-colorspace", value]
        }
        if let value = ffmpegColourValue(colour.range, property: .range) {
            arguments += ["-color_range", value]
        }
        return arguments
    }

    private static func ffmpegColourValue(
        _ value: ColourMetadataValue,
        property: ColourProperty
    ) -> String? {
        guard case let .known(identifier) = value else { return nil }
        return switch (property, identifier) {
        case (.transferFunction, "pq"): "smpte2084"
        case (.transferFunction, "hlg"): "arib-std-b67"
        case (.range, "limited"): "tv"
        case (.range, "full"): "pc"
        default: identifier
        }
    }

    private static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: "mono"
        case 2: "stereo"
        case 3: "2.1"
        case 4: "quad"
        case 5: "5.0"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(channels)c"
        }
    }

    private static func escapedFilterPath(_ url: URL) -> String {
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: ";", with: "\\;")
        return "'\(escaped)'"
    }

    private static func rate(_ rate: FrameRate) -> String {
        "\(rate.numerator)/\(rate.denominator)"
    }

    private static func seconds(_ time: MediaTime) -> TimeInterval {
        Double(time.value) / Double(time.timescale)
    }

    private static func time(_ value: TimeInterval) -> String {
        String(format: "%.9f", value)
    }
}
