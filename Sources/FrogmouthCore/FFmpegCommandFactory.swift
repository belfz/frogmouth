import Foundation

public struct VideoPipelinePlan: Equatable, Sendable {
    public let inputStart: TimeInterval
    public let absoluteSourceStart: TimeInterval
    public let duration: TimeInterval
    public let filters: [String]

    public init(
        inputStart: TimeInterval,
        absoluteSourceStart: TimeInterval,
        duration: TimeInterval,
        filters: [String]
    ) {
        self.inputStart = inputStart
        self.absoluteSourceStart = absoluteSourceStart
        self.duration = duration
        self.filters = filters
    }
}
public enum FFmpegCommandFactory {
    public static func pipeline(sourceDuration: TimeInterval, operations: [EditOperation]) -> VideoPipelinePlan {
        var inputStart: TimeInterval = 0
        var absoluteSourceStart: TimeInterval = 0
        var duration = sourceDuration
        var filters: [String] = []
        var encounteredStabilization = false

        for operation in operations {
            switch operation {
            case let .trim(requestedRange):
                let range = requestedRange.normalized(for: duration)
                absoluteSourceStart += range.start
                if encounteredStabilization {
                    filters += [
                        "trim=start=\(time(range.start)):end=\(time(range.end))",
                        "setpts=PTS-STARTPTS",
                    ]
                } else {
                    inputStart += range.start
                }
                duration = range.duration

            case let .stabilization(pass):
                encounteredStabilization = true
                guard let profile = StabilizationProfile.profile(for: pass.mode) else { continue }
                filters.append(transformFilter(transforms: pass.transformsURL, profile: profile))
            }
        }

        return VideoPipelinePlan(
            inputStart: inputStart,
            absoluteSourceStart: absoluteSourceStart,
            duration: duration,
            filters: filters
        )
    }

    public static func analysis(
        input: URL,
        sourceDuration: TimeInterval,
        operations: [EditOperation],
        transforms: URL,
        profile: StabilizationProfile
    ) -> [String] {
        let plan = pipeline(sourceDuration: sourceDuration, operations: operations)
        var filters = plan.filters
        filters.append(
            "vidstabdetect=result=\(escapedFilterPath(transforms)):shakiness=\(profile.shakiness):accuracy=\(profile.accuracy):stepsize=\(profile.stepSize):fileformat=ascii"
        )

        return baseProgressArguments
            + inputArguments(input: input, start: plan.inputStart)
            + [
                "-y",
                "-map", "0:v:0",
                "-an",
                "-vf", filters.joined(separator: ","),
                "-t", time(plan.duration),
                "-f", "null",
                "-",
            ]
    }

    public static func preview(
        input: URL,
        sourceDuration: TimeInterval,
        operations: [EditOperation],
        output: URL
    ) -> [String] {
        let plan = pipeline(sourceDuration: sourceDuration, operations: operations)
        let filters = plan.filters + ["scale=1024:-2"]

        return baseProgressArguments
            + inputArguments(input: input, start: plan.inputStart)
            + [
                "-y",
                "-map", "0:v:0",
                "-an",
                "-vf", filters.joined(separator: ","),
                "-t", time(plan.duration),
                "-c:v", "hevc_videotoolbox",
                "-b:v", "12M",
                "-tag:v", "hvc1",
                "-movflags", "+faststart",
                output.path,
            ]
    }

    public static func export(
        input: URL,
        sourceDuration: TimeInterval,
        operations: [EditOperation],
        output: URL,
        targetVideoBitrate: Int
    ) -> [String] {
        let plan = pipeline(sourceDuration: sourceDuration, operations: operations)
        let needsSeparateAudioInput = abs(plan.absoluteSourceStart - plan.inputStart) > 0.000_001
        var arguments = baseProgressArguments
            + inputArguments(input: input, start: plan.inputStart)

        if needsSeparateAudioInput {
            arguments += inputArguments(input: input, start: plan.absoluteSourceStart)
        }

        arguments += [
            "-y",
            "-map", "0:v:0",
            "-map", needsSeparateAudioInput ? "1:a?" : "0:a?",
            "-map_metadata", "0",
        ]

        if !plan.filters.isEmpty {
            arguments += ["-vf", plan.filters.joined(separator: ",")]
        }

        arguments += [
            "-t", time(plan.duration),
            "-c:v", "hevc_videotoolbox",
            "-b:v", String(targetVideoBitrate),
            "-tag:v", "hvc1",
            "-c:a", "copy",
            "-movflags", "+faststart",
            output.path,
        ]
        return arguments
    }

    private static let baseProgressArguments = [
        "-hide_banner",
        "-nostdin",
        "-nostats",
        "-progress", "pipe:1",
    ]

    private static func inputArguments(input: URL, start: TimeInterval) -> [String] {
        var arguments: [String] = []
        if start > 0.000_001 {
            arguments += ["-ss", time(start)]
        }
        arguments += ["-i", input.path]
        return arguments
    }

    private static func transformFilter(transforms: URL, profile: StabilizationProfile) -> String {
        "vidstabtransform=input=\(escapedFilterPath(transforms)):smoothing=\(profile.smoothing):optzoom=2:interpol=bicubic"
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
