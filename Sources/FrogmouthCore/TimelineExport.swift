import Darwin
import Foundation

public struct TimelineExportDestinationSuggestion: Equatable, Sendable {
    public let directoryURL: URL
    public let filename: String

    public init(directoryURL: URL, filename: String) {
        self.directoryURL = directoryURL
        self.filename = filename
    }
}

public enum TimelineExportDestinationPolicy {
    public static func suggestion(
        project: ProjectState,
        projectFileURL: URL?,
        mediaURLs: [MediaAsset.ID: URL]
    ) -> TimelineExportDestinationSuggestion? {
        let directory: URL?
        if let projectFileURL {
            directory = projectFileURL.deletingLastPathComponent()
        } else {
            directory = project.clips.lazy
                .compactMap { mediaURLs[$0.assetID] }
                .first?
                .deletingLastPathComponent()
        }
        guard let directory else { return nil }
        return TimelineExportDestinationSuggestion(
            directoryURL: directory,
            filename: "\(safeFilename(project.name))—frogmouth.mp4"
        )
    }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let parts = name.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.joined(separator: "-").isEmpty ? "Untitled" : parts.joined(separator: "-")
    }
}

public struct TimelineExportMetadata: Equatable, Sendable {
    public static let provenance = "Encoded by frogmouth"

    /// FFmpeg container tag names and values copied from every contributing source.
    public let commonSourceTags: [String: String]
    public let creationTime: String
    public let projectName: String

    public init(
        commonSourceTags: [String: String],
        creationTime: String,
        projectName: String
    ) {
        self.commonSourceTags = commonSourceTags
        self.creationTime = creationTime
        self.projectName = projectName
    }

    public var ffmpegTags: [String: String] {
        var result = commonSourceTags
        result["creation_time"] = creationTime
        result["title"] = projectName
        result["comment"] = Self.provenance
        result["encoder"] = Self.provenance
        return result
    }
}

public enum TimelineExportMetadataPolicy {
    /// Metadata that is both useful to the viewer and reliably representable in MP4.
    /// Camera identity, GPS, source creation date, and encoder tags are intentionally excluded.
    private static let safeCommonKeyMap = [
        "albumName": "album",
        "artist": "artist",
        "copyrights": "copyright",
        "type": "genre",
    ]

    public static func metadata(
        projectName: String,
        sourceMetadata: [[String: String]],
        creationDate: Date
    ) -> TimelineExportMetadata {
        var common: [String: String] = [:]
        if let first = sourceMetadata.first {
            for (sourceKey, outputKey) in safeCommonKeyMap {
                guard let candidate = valid(first[sourceKey]),
                      sourceMetadata.dropFirst().allSatisfy({ valid($0[sourceKey]) == candidate }) else {
                    continue
                }
                common[outputKey] = candidate
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return TimelineExportMetadata(
            commonSourceTags: common,
            creationTime: formatter.string(from: creationDate),
            projectName: projectName
        )
    }

    private static func valid(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024 else { return nil }
        return trimmed
    }
}

public enum TimelineExportValidationError: LocalizedError, Equatable, Sendable {
    case emptyOutput
    case unexpectedVideoCodec(String)
    case unexpectedCanvas(width: Int, height: Int)
    case unexpectedFrameRate(FrameRate)
    case unexpectedColour(VideoColourMetadata)
    case missingAudio
    case unexpectedAudioCodec(String?)
    case unexpectedAudioFormat(sampleRate: Double?, channels: Int?)
    case unexpectedDuration(actual: MediaTime, expected: MediaTime)
    case missingMetadata(String)
    case incorrectMetadata(key: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput:
            return "The rendered file is empty."
        case let .unexpectedVideoCodec(codec):
            return "The rendered video codec is \(codec), not the requested export codec."
        case let .unexpectedCanvas(width, height):
            return "The rendered canvas is \(width)×\(height), which does not match the timeline."
        case let .unexpectedFrameRate(rate):
            return "The rendered frame rate is \(rate.numerator)/\(rate.denominator), which does not match the timeline."
        case .unexpectedColour:
            return "The rendered colour metadata does not match the timeline."
        case .missingAudio:
            return "The rendered file is missing timeline audio."
        case let .unexpectedAudioCodec(codec):
            return "The rendered audio codec \(codec ?? "none") does not match the export policy."
        case let .unexpectedAudioFormat(sampleRate, channels):
            let displayedRate = sampleRate.map { String($0) } ?? "unknown"
            let displayedChannels = channels.map { String($0) } ?? "unknown"
            return "The rendered audio format \(displayedRate) Hz / \(displayedChannels) channels does not match the timeline."
        case let .unexpectedDuration(actual, expected):
            return "The rendered duration \(actual.value)/\(actual.timescale) does not match the expected \(expected.value)/\(expected.timescale)."
        case let .missingMetadata(key):
            return "The rendered file is missing required \(key) metadata."
        case let .incorrectMetadata(key, expected):
            return "The rendered \(key) metadata does not contain \(expected)."
        }
    }
}

public struct TimelineExportValidator: Sendable {
    public init() {}

    public func validate(
        output: MediaInfo,
        against plan: TimelineRenderPlan,
        metadata: TimelineExportMetadata,
        encoding: TimelineRenderEncoding = .delivery
    ) throws {
        guard output.fileSize > 0 else { throw TimelineExportValidationError.emptyOutput }
        let codec = output.videoCodec.lowercased()
        let validVideoCodec = switch encoding {
        case .delivery: codec.contains("hvc") || codec.contains("hev")
        case .verification: codec.contains("apcn") || codec.contains("prores")
        }
        guard validVideoCodec else {
            throw TimelineExportValidationError.unexpectedVideoCodec(output.videoCodec)
        }
        guard output.width == plan.format.width, output.height == plan.format.height else {
            throw TimelineExportValidationError.unexpectedCanvas(
                width: output.width,
                height: output.height
            )
        }
        guard output.exactFrameRate == plan.format.frameRate else {
            throw TimelineExportValidationError.unexpectedFrameRate(output.exactFrameRate)
        }
        let colourMatches = switch encoding {
        case .delivery:
            output.colour == plan.format.colour
        case .verification:
            output.colour.primaries == plan.format.colour.primaries
                && output.colour.transferFunction == plan.format.colour.transferFunction
                && output.colour.matrix == plan.format.colour.matrix
        }
        guard colourMatches else {
            throw TimelineExportValidationError.unexpectedColour(output.colour)
        }
        if plan.hasAudio {
            guard let audioCodec = output.audioCodec else {
                throw TimelineExportValidationError.missingAudio
            }
            let normalizedCodec = audioCodec.lowercased()
            let validAudioCodec = switch encoding {
            case .delivery: normalizedCodec.contains("aac") || normalizedCodec == "mp4a"
            case .verification:
                normalizedCodec.contains("lpcm")
                    || normalizedCodec.contains("pcm")
                    || normalizedCodec == "sowt"
            }
            guard validAudioCodec else {
                throw TimelineExportValidationError.unexpectedAudioCodec(output.audioCodec)
            }
            guard output.audioSampleRate.map({ Int($0.rounded()) }) == plan.format.audioSampleRate,
                  output.audioChannelCount == plan.format.audioChannelCount else {
                throw TimelineExportValidationError.unexpectedAudioFormat(
                    sampleRate: output.audioSampleRate,
                    channels: output.audioChannelCount
                )
            }
        } else if output.audioCodec != nil {
            throw TimelineExportValidationError.unexpectedAudioCodec(output.audioCodec)
        }

        let actualFrames = try plan.format.frameRate.frameIndex(
            for: output.exactDuration,
            rounding: .nearestTiesAwayFromZero
        )
        guard abs(actualFrames - plan.totalFrames) <= 1 else {
            throw TimelineExportValidationError.unexpectedDuration(
                actual: output.exactDuration,
                expected: plan.totalDuration
            )
        }
        try validateMetadata(output.metadata, expected: metadata)
    }

    private func validateMetadata(
        _ actual: [String: String],
        expected: TimelineExportMetadata
    ) throws {
        let normalized = actual.reduce(into: [String: String]()) {
            $0[$1.key.lowercased()] = $1.value
        }
        guard metadataValue(["title"], in: normalized) == expected.projectName else {
            throw TimelineExportValidationError.incorrectMetadata(
                key: "project name",
                expected: expected.projectName
            )
        }
        guard let creationTime = metadataValue(["creationdate", "creation_time"], in: normalized) else {
            throw TimelineExportValidationError.missingMetadata("creation time")
        }
        guard equivalentTimestamp(creationTime, expected.creationTime) else {
            throw TimelineExportValidationError.incorrectMetadata(
                key: "creation time",
                expected: expected.creationTime
            )
        }
        let provenanceValues = ["comment", "description", "encoder", "software"]
            .compactMap { normalized[$0] }
        guard provenanceValues.contains(where: { $0.contains(TimelineExportMetadata.provenance) }) else {
            throw TimelineExportValidationError.incorrectMetadata(
                key: "provenance",
                expected: TimelineExportMetadata.provenance
            )
        }
        for (key, value) in expected.commonSourceTags {
            let aliases: [String] = switch key {
            case "album": ["album", "albumname"]
            case "copyright": ["copyright", "copyrights"]
            case "genre": ["genre", "type"]
            default: [key]
            }
            guard metadataValue(aliases, in: normalized) == value else {
                throw TimelineExportValidationError.incorrectMetadata(
                    key: key,
                    expected: value
                )
            }
        }
    }

    private func metadataValue(_ keys: [String], in metadata: [String: String]) -> String? {
        for key in keys {
            if let exact = metadata[key] { return exact }
            if let identified = metadata.first(where: { $0.key.contains(key) })?.value {
                return identified
            }
        }
        return nil
    }

    private func equivalentTimestamp(_ actual: String, _ expected: String) -> Bool {
        if actual == expected { return true }
        func date(_ value: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            return wholeSeconds.date(from: value)
        }
        guard let actualDate = date(actual), let expectedDate = date(expected) else { return false }
        return abs(actualDate.timeIntervalSince(expectedDate)) < 0.001
    }
}

public enum TimelineExportFileError: LocalizedError, Equatable, Sendable {
    case finalizationFailed(path: String, errorCode: Int32)

    public var errorDescription: String? {
        switch self {
        case let .finalizationFailed(path, code):
            "The export could not replace \(path) (system error \(code)). The previous file was left unchanged."
        }
    }
}

public protocol TimelineExportFileFinalizing: Sendable {
    func finalize(temporaryURL: URL, destinationURL: URL) throws
}

public struct AtomicTimelineExportFileFinalizer: TimelineExportFileFinalizing {
    public init() {}

    public func finalize(temporaryURL: URL, destinationURL: URL) throws {
        let status = temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let temporaryPath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(temporaryPath, destinationPath)
            }
        }
        guard status == 0 else {
            throw TimelineExportFileError.finalizationFailed(
                path: destinationURL.path,
                errorCode: errno
            )
        }
    }
}

public struct TimelineExportRequest: Sendable {
    public let renderRequest: TimelineRenderRequest
    public let destinationURL: URL
    public let installation: FFmpegInstallation
    public let sessionID: String

    public init(
        renderRequest: TimelineRenderRequest,
        destinationURL: URL,
        installation: FFmpegInstallation,
        sessionID: String
    ) {
        self.renderRequest = renderRequest
        self.destinationURL = destinationURL
        self.installation = installation
        self.sessionID = sessionID
    }
}

public struct TimelineExportResult: Equatable, Sendable {
    public let destinationURL: URL
    public let metadata: TimelineExportMetadata

    public init(destinationURL: URL, metadata: TimelineExportMetadata) {
        self.destinationURL = destinationURL
        self.metadata = metadata
    }
}

public final class TimelineExporter: @unchecked Sendable {
    private let runner: any FFmpegExecuting
    private let inspector: any MediaInspecting
    private let finalizer: any TimelineExportFileFinalizing
    private let creationDate: @Sendable () -> Date

    public init(
        runner: any FFmpegExecuting,
        inspector: any MediaInspecting = MediaInspector(),
        finalizer: any TimelineExportFileFinalizing = AtomicTimelineExportFileFinalizer(),
        creationDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.inspector = inspector
        self.finalizer = finalizer
        self.creationDate = creationDate
    }

    public func export(
        _ request: TimelineExportRequest,
        encoding: TimelineRenderEncoding = .delivery,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimelineExportResult {
        let plan = try TimelineRenderPlanner().plan(request.renderRequest)
        var sourceMetadata: [[String: String]] = []
        for input in plan.inputs.sorted(by: { $0.index < $1.index }) {
            try Task.checkCancellation()
            sourceMetadata.append(try await inspector.inspect(url: input.url).metadata)
        }
        let metadata = TimelineExportMetadataPolicy.metadata(
            projectName: request.renderRequest.project.name,
            sourceMetadata: sourceMetadata,
            creationDate: creationDate()
        )
        let temporaryURL = Self.temporaryURL(for: request.destinationURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        _ = try await runner.run(
            executable: request.installation.executableURL,
            arguments: try TimelineFFmpegCommandFactory.arguments(
                for: plan,
                output: temporaryURL,
                encoding: encoding,
                metadata: metadata
            ),
            duration: Double(plan.totalDuration.value) / Double(plan.totalDuration.timescale),
            sessionID: request.sessionID,
            phase: "timeline-export",
            progress: progress
        )
        try Task.checkCancellation()
        let output = try await inspector.inspect(url: temporaryURL)
        try TimelineExportValidator().validate(
            output: output,
            against: plan,
            metadata: metadata,
            encoding: encoding
        )
        try Task.checkCancellation()
        try finalizer.finalize(temporaryURL: temporaryURL, destinationURL: request.destinationURL)
        return TimelineExportResult(
            destinationURL: request.destinationURL,
            metadata: metadata
        )
    }

    public func cancel() {
        runner.cancel()
    }

    public static func temporaryURL(for destinationURL: URL) -> URL {
        let pathExtension = destinationURL.pathExtension.isEmpty
            ? "mp4"
            : destinationURL.pathExtension
        return destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.deletingPathExtension().lastPathComponent).frogmouth-\(UUID().uuidString).partial.\(pathExtension)"
        )
    }
}
