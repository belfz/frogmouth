@preconcurrency import AVFoundation
import AppKit
import Foundation

public struct ThumbnailRequest: Hashable, Sendable {
    public static let processingRevision = 1

    public let assetID: MediaAsset.ID
    public let sourceFingerprint: MediaFingerprint
    public let mediaURL: URL
    public let sourceFrame: Int64
    public let sourceTime: MediaTime
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        assetID: MediaAsset.ID,
        sourceFingerprint: MediaFingerprint,
        mediaURL: URL,
        frameRate: FrameRate,
        requestedSourceTime: MediaTime,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw ThumbnailError.invalidDimensions(width: pixelWidth, height: pixelHeight)
        }
        let sourceFrame = try frameRate.frameIndex(
            for: requestedSourceTime,
            rounding: .nearestTiesAwayFromZero
        )
        self.assetID = assetID
        self.sourceFingerprint = sourceFingerprint
        self.mediaURL = mediaURL.standardizedFileURL
        self.sourceFrame = sourceFrame
        sourceTime = try frameRate.time(forFrame: sourceFrame)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var cacheIdentity: CacheEntryIdentity {
        CacheEntryIdentity(
            namespace: "original-source-thumbnail",
            logicalArtifactID: "frame-\(sourceFrame)-\(pixelWidth)x\(pixelHeight)",
            assetID: assetID,
            sourceFingerprint: sourceFingerprint,
            processingRevision: Self.processingRevision,
            orderedParameters: [
                CacheKeyComponent(
                    name: "source-time",
                    value: "\(sourceTime.value)/\(sourceTime.timescale)"
                ),
                CacheKeyComponent(name: "pixel-width", value: "\(pixelWidth)"),
                CacheKeyComponent(name: "pixel-height", value: "\(pixelHeight)"),
            ]
        )
    }
}

public enum ThumbnailError: LocalizedError, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case imageEncodingFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidDimensions(width, height):
            "The thumbnail dimensions are invalid: \(width)×\(height)."
        case .imageEncodingFailed:
            "The generated thumbnail could not be encoded as JPEG."
        }
    }
}

public protocol ThumbnailGenerating: Sendable {
    func generateJPEG(for request: ThumbnailRequest) async throws -> Data
}

public struct AVThumbnailGenerator: ThumbnailGenerating, Sendable {
    public init() {}

    public func generateJPEG(for request: ThumbnailRequest) async throws -> Data {
        let asset = AVURLAsset(url: request.mediaURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: request.pixelWidth, height: request.pixelHeight)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        return try await withTaskCancellationHandler {
            let result = try await generator.image(at: request.sourceTime.cmTime)
            try Task.checkCancellation()
            let representation = NSBitmapImageRep(cgImage: result.image)
            guard let data = representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.82]
            ) else {
                throw ThumbnailError.imageEncodingFailed
            }
            return data
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }
}

public actor ThumbnailService {
    private struct WorkKey: Hashable {
        let projectID: ProjectState.ID
        let cacheKey: String
    }

    private struct InFlightWork {
        let id: UUID
        let task: Task<URL, Error>
        var consumers: Set<UUID>
    }

    private let cacheStore: ProjectCacheStore
    private let generator: any ThumbnailGenerating
    private let keyBuilder: CacheKeyBuilder
    private var inFlight: [WorkKey: InFlightWork] = [:]

    public init(
        cacheStore: ProjectCacheStore = ProjectCacheStore(),
        generator: any ThumbnailGenerating = AVThumbnailGenerator(),
        keyBuilder: CacheKeyBuilder = CacheKeyBuilder()
    ) {
        self.cacheStore = cacheStore
        self.generator = generator
        self.keyBuilder = keyBuilder
    }

    public func thumbnail(
        for request: ThumbnailRequest,
        projectID: ProjectState.ID,
        consumerID: UUID
    ) async throws -> URL {
        let cacheKey = try keyBuilder.key(for: request.cacheIdentity)
        let workKey = WorkKey(projectID: projectID, cacheKey: cacheKey)
        switch await cacheStore.lookup(projectID: projectID, identity: request.cacheIdentity) {
        case let .hit(artifact):
            return artifact.url
        case .stale:
            break
        }

        let work: InFlightWork
        if var existing = inFlight[workKey] {
            existing.consumers.insert(consumerID)
            inFlight[workKey] = existing
            work = existing
        } else {
            let id = UUID()
            let task = Task { [cacheStore, generator] in
                let data = try await generator.generateJPEG(for: request)
                try Task.checkCancellation()
                let artifact = try await cacheStore.store(
                    data,
                    projectID: projectID,
                    identity: request.cacheIdentity,
                    fileExtension: "jpg"
                )
                return artifact.url
            }
            work = InFlightWork(id: id, task: task, consumers: [consumerID])
            inFlight[workKey] = work
        }

        do {
            let url = try await work.task.value
            removeWorkIfCurrent(workKey, id: work.id)
            return url
        } catch {
            removeWorkIfCurrent(workKey, id: work.id)
            throw error
        }
    }

    public func cancel(
        request: ThumbnailRequest,
        projectID: ProjectState.ID,
        consumerID: UUID
    ) {
        guard let cacheKey = try? keyBuilder.key(for: request.cacheIdentity) else { return }
        let workKey = WorkKey(projectID: projectID, cacheKey: cacheKey)
        guard var work = inFlight[workKey] else { return }
        work.consumers.remove(consumerID)
        guard work.consumers.isEmpty else {
            inFlight[workKey] = work
            return
        }
        work.task.cancel()
        inFlight[workKey] = nil
    }

    private func removeWorkIfCurrent(_ key: WorkKey, id: UUID) {
        if inFlight[key]?.id == id { inFlight[key] = nil }
    }
}
