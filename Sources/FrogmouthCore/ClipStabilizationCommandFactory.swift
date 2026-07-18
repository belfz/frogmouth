import Foundation

public enum ClipStabilizationCommandError: LocalizedError, Equatable, Sendable {
    case invalidEffectIndex(Int)
    case unsupportedMode(StabilizationEffect.ID)
    case missingTransforms(StabilizationEffect.ID)
    case nonNestedAnalysisCoverage(
        parent: StabilizationEffect.ID,
        child: StabilizationEffect.ID
    )

    public var errorDescription: String? {
        switch self {
        case let .invalidEffectIndex(index):
            "Stabilization pass index \(index) is outside the configured stack."
        case let .unsupportedMode(effectID):
            "Stabilization pass \(effectID.uuidString) has no processing profile."
        case let .missingTransforms(effectID):
            "Transforms for preceding stabilization pass \(effectID.uuidString) are unavailable."
        case let .nonNestedAnalysisCoverage(parent, child):
            "Stabilization pass \(child.uuidString) extends outside preceding pass \(parent.uuidString). Update stabilization."
        }
    }
}

public enum ClipStabilizationCommandFactory {
    public static func analysis(
        input: URL,
        clip: TimelineClip,
        effectIndex: Int,
        precedingTransforms: [StabilizationEffect.ID: URL],
        outputTransforms: URL
    ) throws -> [String] {
        let pipeline = try prefixPipeline(
            clip: clip,
            targetIndex: effectIndex,
            transforms: precedingTransforms
        )
        let target = clip.stabilizationPasses[effectIndex]
        guard let profile = StabilizationProfile.profile(for: target.mode) else {
            throw ClipStabilizationCommandError.unsupportedMode(target.id)
        }
        let filters = pipeline.filters + [
            "vidstabdetect=result=\(escapedFilterPath(outputTransforms)):shakiness=\(profile.shakiness):accuracy=\(profile.accuracy):stepsize=\(profile.stepSize):fileformat=ascii",
        ]

        return baseProgressArguments
            + inputArguments(input: input, start: pipeline.inputStart)
            + [
                "-y",
                "-map", "0:v:0",
                "-an",
                "-vf", filters.joined(separator: ","),
                "-t", time(pipeline.outputDuration),
                "-f", "null",
                "-",
            ]
    }

    public static func preview(
        input: URL,
        clip: TimelineClip,
        effectIndex: Int,
        transforms: [StabilizationEffect.ID: URL],
        output: URL,
        pixelWidth: Int = StabilizationCacheIdentityBuilder.previewPixelWidth
    ) throws -> [String] {
        let pipeline = try prefixPipeline(
            clip: clip,
            targetIndex: effectIndex,
            transforms: transforms
        )
        let target = clip.stabilizationPasses[effectIndex]
        guard let targetTransforms = transforms[target.id] else {
            throw ClipStabilizationCommandError.missingTransforms(target.id)
        }
        guard let profile = StabilizationProfile.profile(for: target.mode) else {
            throw ClipStabilizationCommandError.unsupportedMode(target.id)
        }
        let filters = pipeline.filters + [
            transformFilter(
                transforms: targetTransforms,
                profile: profile,
                interpolation: "bilinear"
            ),
            "scale=\(pixelWidth):-2",
            "setsar=1",
        ]

        return baseProgressArguments
            + inputArguments(input: input, start: pipeline.inputStart)
            + inputArguments(input: input, start: seconds(target.analysisCoverage.start))
            + [
                "-y",
                "-map", "0:v:0",
                "-map", "1:a?",
                "-vf", filters.joined(separator: ","),
                "-t", time(pipeline.outputDuration),
                "-c:v", "hevc_videotoolbox",
                "-b:v", "12M",
                "-tag:v", "hvc1",
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart",
                output.path,
            ]
    }

    private struct PrefixPipeline {
        let inputStart: TimeInterval
        let outputDuration: TimeInterval
        let filters: [String]
    }

    private static func prefixPipeline(
        clip: TimelineClip,
        targetIndex: Int,
        transforms: [StabilizationEffect.ID: URL]
    ) throws -> PrefixPipeline {
        guard clip.stabilizationPasses.indices.contains(targetIndex) else {
            throw ClipStabilizationCommandError.invalidEffectIndex(targetIndex)
        }
        let effects = clip.stabilizationPasses
        var currentCoverage = effects[0].analysisCoverage
        var filters: [String] = []

        if targetIndex > 0 {
            for index in 0..<targetIndex {
                let effect = effects[index]
                guard let transformURL = transforms[effect.id] else {
                    throw ClipStabilizationCommandError.missingTransforms(effect.id)
                }
                guard let profile = StabilizationProfile.profile(for: effect.mode) else {
                    throw ClipStabilizationCommandError.unsupportedMode(effect.id)
                }
                filters.append(transformFilter(
                    transforms: transformURL,
                    profile: profile,
                    interpolation: "bicubic"
                ))

                let next = effects[index + 1]
                guard contains(currentCoverage, next.analysisCoverage) else {
                    throw ClipStabilizationCommandError.nonNestedAnalysisCoverage(
                        parent: effect.id,
                        child: next.id
                    )
                }
                if next.analysisCoverage != currentCoverage {
                    let relativeStart = try next.analysisCoverage.start.subtracting(
                        currentCoverage.start
                    )
                    filters += [
                        "trim=start=\(time(seconds(relativeStart))):duration=\(time(seconds(next.analysisCoverage.duration)))",
                        "setpts=PTS-STARTPTS",
                    ]
                }
                currentCoverage = next.analysisCoverage
            }
        }

        return PrefixPipeline(
            inputStart: seconds(effects[0].analysisCoverage.start),
            outputDuration: seconds(effects[targetIndex].analysisCoverage.duration),
            filters: filters
        )
    }

    private static let baseProgressArguments = [
        "-hide_banner",
        "-nostdin",
        "-nostats",
        "-progress", "pipe:1",
    ]

    private static func inputArguments(input: URL, start: TimeInterval) -> [String] {
        var arguments: [String] = []
        if start > 0.000_001 { arguments += ["-ss", time(start)] }
        arguments += ["-i", input.path]
        return arguments
    }

    private static func transformFilter(
        transforms: URL,
        profile: StabilizationProfile,
        interpolation: String
    ) -> String {
        "vidstabtransform=input=\(escapedFilterPath(transforms)):smoothing=\(profile.smoothing):optzoom=2:interpol=\(interpolation)"
    }

    private static func contains(_ parent: MediaTimeRange, _ child: MediaTimeRange) -> Bool {
        guard let parentEnd = try? parent.end(),
              let childEnd = try? child.end() else { return false }
        return child.start >= parent.start && childEnd <= parentEnd
    }

    private static func seconds(_ time: MediaTime) -> TimeInterval {
        Double(time.value) / Double(time.timescale)
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

    private static func time(_ value: TimeInterval) -> String {
        String(format: "%.6f", value)
    }
}
