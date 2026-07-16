import CoreMedia
import Foundation

public struct MediaInfo: Equatable, Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let width: Int
    public let height: Int
    public let frameRate: Double
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
        width: Int,
        height: Int,
        frameRate: Double,
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
        self.width = width
        self.height = height
        self.frameRate = frameRate
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

public struct TrimRange: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }

    public func normalized(for mediaDuration: TimeInterval, minimumDuration: TimeInterval = 0.1) -> TrimRange {
        let boundedStart = min(max(0, start), max(0, mediaDuration - minimumDuration))
        let boundedEnd = min(max(boundedStart + minimumDuration, end), mediaDuration)
        return TrimRange(start: boundedStart, end: boundedEnd)
    }
}

public enum StabilizationMode: String, CaseIterable, Identifiable, Sendable {
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

public struct StabilizationPass: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let mode: StabilizationMode
    public let transformsURL: URL

    public init(id: UUID = UUID(), mode: StabilizationMode, transformsURL: URL) {
        self.id = id
        self.mode = mode
        self.transformsURL = transformsURL
    }
}

public enum EditOperation: Equatable, Sendable {
    case trim(TrimRange)
    case stabilization(StabilizationPass)
}

public struct EditState: Equatable, Sendable {
    public let sourceDuration: TimeInterval
    public var operations: [EditOperation]
    public var pendingTrim: TrimRange

    public init(
        sourceDuration: TimeInterval,
        operations: [EditOperation] = [],
        pendingTrim: TrimRange? = nil
    ) {
        self.sourceDuration = sourceDuration
        self.operations = operations
        self.pendingTrim = pendingTrim ?? TrimRange(start: 0, end: sourceDuration)
    }

    public var duration: TimeInterval {
        operations.reduce(sourceDuration) { duration, operation in
            switch operation {
            case let .trim(range): range.normalized(for: duration).duration
            case .stabilization: duration
            }
        }
    }

    public var hasPendingTrim: Bool {
        let fullRange = TrimRange(start: 0, end: duration)
        return abs(pendingTrim.start - fullRange.start) > 0.000_001
            || abs(pendingTrim.end - fullRange.end) > 0.000_001
    }

    public var hasStabilization: Bool {
        operations.contains {
            if case .stabilization = $0 { true } else { false }
        }
    }

    public func committingPendingTrim() -> EditState {
        guard hasPendingTrim else { return self }
        let committed = pendingTrim.normalized(for: duration)
        return EditState(
            sourceDuration: sourceDuration,
            operations: operations + [.trim(committed)],
            pendingTrim: TrimRange(start: 0, end: committed.duration)
        )
    }

    public func appending(_ pass: StabilizationPass) -> EditState {
        EditState(
            sourceDuration: sourceDuration,
            operations: operations + [.stabilization(pass)],
            pendingTrim: TrimRange(start: 0, end: duration)
        )
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
    case invalidTrimRange
    case processingFailed(String)
    case cancelled
    case outputValidationFailed(String)
    case fileOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            "A supported FFmpeg installation was not found."
        case let .unsupportedFFmpeg(message):
            "This FFmpeg installation is unsupported: \(message)"
        case let .unsupportedMedia(message):
            "The video cannot be opened: \(message)"
        case let .incompatibleColour(message):
            message
        case .invalidTrimRange:
            "The selected trim range is invalid."
        case let .processingFailed(message):
            "FFmpeg processing failed: \(message)"
        case .cancelled:
            "Processing was cancelled."
        case let .outputValidationFailed(message):
            "The exported file failed validation: \(message)"
        case let .fileOperationFailed(message):
            "A file operation failed: \(message)"
        }
    }
}
