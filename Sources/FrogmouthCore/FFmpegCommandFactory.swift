import Foundation

public enum FFmpegCommandFactory {
    public static func analysis(
        input: URL,
        trim: TrimRange,
        transforms: URL,
        profile: StabilizationProfile
    ) -> [String] {
        baseProgressArguments + [
            "-y",
            "-i", input.path,
            "-ss", time(trim.start),
            "-t", time(trim.duration),
            "-map", "0:v:0",
            "-an",
            "-vf", "vidstabdetect=result=\(escapedFilterPath(transforms)):shakiness=\(profile.shakiness):accuracy=\(profile.accuracy):stepsize=\(profile.stepSize):fileformat=ascii",
            "-f", "null",
            "-",
        ]
    }

    public static func preview(
        input: URL,
        trim: TrimRange,
        transforms: URL,
        output: URL,
        profile: StabilizationProfile
    ) -> [String] {
        baseProgressArguments + [
            "-y",
            "-i", input.path,
            "-ss", time(trim.start),
            "-t", time(trim.duration),
            "-map", "0:v:0",
            "-an",
            "-vf", "\(transformFilter(transforms: transforms, profile: profile)),scale=1024:-2",
            "-c:v", "hevc_videotoolbox",
            "-b:v", "12M",
            "-tag:v", "hvc1",
            "-movflags", "+faststart",
            output.path,
        ]
    }

    public static func export(
        input: URL,
        trim: TrimRange,
        transforms: URL?,
        output: URL,
        profile: StabilizationProfile?,
        targetVideoBitrate: Int
    ) -> [String] {
        var arguments = baseProgressArguments + [
            "-y",
            "-i", input.path,
            "-ss", time(trim.start),
            "-t", time(trim.duration),
            "-map", "0:v:0",
            "-map", "0:a?",
            "-map_metadata", "0",
        ]

        if let transforms, let profile {
            arguments += ["-vf", transformFilter(transforms: transforms, profile: profile)]
        }

        arguments += [
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
