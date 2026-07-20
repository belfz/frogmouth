import CoreMedia
import Foundation

public struct MediaInfo: Equatable, Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let exactDuration: MediaTime
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let exactFrameRate: FrameRate
    public let videoBitrate: Double
    public let videoCodec: String
    public let audioCodec: String?
    public let audioSampleRate: Double?
    public let audioChannelCount: Int?
    public let fileSize: Int64
    public let metadata: [String: String]
    public let colour: VideoColourMetadata

    public init(
        url: URL,
        duration: TimeInterval,
        exactDuration: MediaTime,
        width: Int,
        height: Int,
        frameRate: Double,
        exactFrameRate: FrameRate,
        videoBitrate: Double,
        videoCodec: String,
        audioCodec: String?,
        audioSampleRate: Double?,
        audioChannelCount: Int?,
        fileSize: Int64,
        metadata: [String: String],
        colour: VideoColourMetadata = .unspecified
    ) {
        self.url = url
        self.duration = duration
        self.exactDuration = exactDuration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.exactFrameRate = exactFrameRate
        self.videoBitrate = videoBitrate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.fileSize = fileSize
        self.metadata = metadata
        self.colour = colour
    }
}

public enum StabilizationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case steady
    case naturalMotion

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Off"
        case .steady: "Steady"
        case .naturalMotion: "Natural motion"
        }
    }
}

public struct StabilizationProfile: Equatable, Sendable {
    public let shakiness: Int
    public let accuracy: Int
    public let stepSize: Int
    public let smoothing: Int

    public static func profile(for mode: StabilizationMode) -> StabilizationProfile? {
        switch mode {
        case .none:
            nil
        case .steady:
            StabilizationProfile(shakiness: 8, accuracy: 9, stepSize: 12, smoothing: 30)
        case .naturalMotion:
            StabilizationProfile(shakiness: 5, accuracy: 9, stepSize: 12, smoothing: 8)
        }
    }
}

public enum ProcessingPhase: Equatable, Sendable {
    case idle
    case analyzing(progress: Double?)
    case renderingPreview(progress: Double?)
    case exporting(progress: Double?)

    public var title: String {
        switch self {
        case .idle: ""
        case .analyzing: "Analyzing stabilization…"
        case .renderingPreview: "Rendering preview…"
        case .exporting: "Exporting video…"
        }
    }

    public var progress: Double? {
        switch self {
        case .idle: nil
        case let .analyzing(progress), let .renderingPreview(progress), let .exporting(progress): progress
        }
    }
}

public enum FrogmouthError: LocalizedError, Equatable, Sendable {
    case ffmpegNotFound
    case unsupportedFFmpeg(String)
    case unsupportedMedia(String)
    case incompatibleColour(String)
    case processingFailed(String)
    case cancelled
    case outputValidationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            "A supported FFmpeg installation was not found. Install FFmpeg, restart frogmouth, and try again."
        case let .unsupportedFFmpeg(message):
            "This FFmpeg installation is unsupported: \(message) Install a supported FFmpeg version, restart frogmouth, and try again."
        case let .unsupportedMedia(message):
            "The video cannot be opened: \(message) Choose a readable video file and try again."
        case let .incompatibleColour(message):
            message
        case let .processingFailed(message):
            "FFmpeg processing failed: \(message) Retry the operation; if it fails again, copy the diagnostics for investigation."
        case .cancelled:
            "Processing was cancelled."
        case let .outputValidationFailed(message):
            "The exported file failed validation: \(message) The previous export was left unchanged; retry or copy the diagnostics for investigation."
        }
    }
}
