import AppKit
import Foundation
import Testing

@testable import FrogmouthCore

@Test func timelineThumbnailWidthsUseStableRetinaBuckets() {
    #expect(ThumbnailSizing.quantizedPixelWidth(displayWidth: 1) == 160)
    #expect(ThumbnailSizing.quantizedPixelWidth(displayWidth: 80) == 160)
    #expect(ThumbnailSizing.quantizedPixelWidth(displayWidth: 80.1) == 320)
    #expect(ThumbnailSizing.quantizedPixelWidth(displayWidth: 159.9) == 320)
    #expect(ThumbnailSizing.quantizedPixelWidth(displayWidth: 160.1) == 640)
    #expect(ThumbnailSizing.quantizedPixelWidth(displayWidth: 10_000) == 640)
    #expect(ThumbnailSizing.quantizedPixelWidth(displayWidth: .nan) == 160)
}

@Test func thumbnailRequestsSnapExactlyAndIgnoreStabilizationState() throws {
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let assetID = UUID(uuidString: "AAAAAAAA-A000-0000-0000-000000000001")!
    let fingerprint = MediaFingerprint(fileSize: 100, modificationTimeNanoseconds: 200)
    let requested = try MediaTime(value: 51, timescale: 100)
    let first = try ThumbnailRequest(
        assetID: assetID,
        sourceFingerprint: fingerprint,
        mediaURL: URL(fileURLWithPath: "/tmp/source.mp4"),
        frameRate: rate,
        requestedSourceTime: requested,
        pixelWidth: 320,
        pixelHeight: 180
    )
    let duplicate = try ThumbnailRequest(
        assetID: assetID,
        sourceFingerprint: fingerprint,
        mediaURL: URL(fileURLWithPath: "/tmp/source.mp4"),
        frameRate: rate,
        requestedSourceTime: requested,
        pixelWidth: 320,
        pixelHeight: 180
    )
    let trimmed = try ThumbnailRequest(
        assetID: assetID,
        sourceFingerprint: fingerprint,
        mediaURL: URL(fileURLWithPath: "/tmp/source.mp4"),
        frameRate: rate,
        requestedSourceTime: try rate.time(forFrame: 24),
        pixelWidth: 320,
        pixelHeight: 180
    )

    let expectedSourceTime = try rate.time(forFrame: 12)
    #expect(first.sourceFrame == 12)
    #expect(first.sourceTime == expectedSourceTime)
    #expect(first == duplicate)
    #expect(first.cacheIdentity == duplicate.cacheIdentity)
    #expect(first.cacheIdentity != trimmed.cacheIdentity)
    #expect(first.cacheIdentity.namespace == "original-source-thumbnail")
    #expect(first.cacheIdentity.toolRevision == nil)
}

@Test func thumbnailServiceDeduplicatesConcurrentConsumersAndReusesPersistentCache() async throws {
    let root = try makeThumbnailTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheStore = ProjectCacheStore(rootURL: root.appendingPathComponent("cache"))
    let generator = StubThumbnailGenerator(data: Data("thumbnail".utf8), delay: .milliseconds(40))
    let service = ThumbnailService(cacheStore: cacheStore, generator: generator)
    let request = try makeThumbnailRequest()
    let projectID = UUID(uuidString: "AAAAAAAA-A100-0000-0000-000000000001")!
    let firstConsumer = UUID()
    let secondConsumer = UUID()

    async let first = service.thumbnail(
        for: request,
        projectID: projectID,
        consumerID: firstConsumer
    )
    async let second = service.thumbnail(
        for: request,
        projectID: projectID,
        consumerID: secondConsumer
    )
    let firstURL = try await first
    let secondURL = try await second
    let generatedCount = await generator.generationCount
    #expect(firstURL == secondURL)
    #expect(generatedCount == 1)
    #expect(try Data(contentsOf: firstURL) == Data("thumbnail".utf8))

    let recreated = ThumbnailService(
        cacheStore: ProjectCacheStore(rootURL: root.appendingPathComponent("cache")),
        generator: FailingThumbnailGenerator()
    )
    let cachedURL = try await recreated.thumbnail(
        for: request,
        projectID: projectID,
        consumerID: UUID()
    )
    #expect(try Data(contentsOf: cachedURL) == Data("thumbnail".utf8))
}

@Test func cancellingTheLastVisibleConsumerCancelsGeneration() async throws {
    let root = try makeThumbnailTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let generator = StubThumbnailGenerator(data: Data([1]), delay: .seconds(2))
    let service = ThumbnailService(
        cacheStore: ProjectCacheStore(rootURL: root.appendingPathComponent("cache")),
        generator: generator
    )
    let request = try makeThumbnailRequest()
    let projectID = UUID(uuidString: "AAAAAAAA-A200-0000-0000-000000000001")!
    let consumerID = UUID()
    let task = Task {
        try await service.thumbnail(
            for: request,
            projectID: projectID,
            consumerID: consumerID
        )
    }
    try await Task.sleep(for: .milliseconds(30))
    await service.cancel(request: request, projectID: projectID, consumerID: consumerID)

    do {
        _ = try await task.value
        Issue.record("Expected the unobserved thumbnail generation to be cancelled")
    } catch is CancellationError {
        // Expected.
    }
}

@Test func avThumbnailGeneratorProducesABoundedJPEGFromTheMediaFixture() async throws {
    let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/test-media-fixtures/base-24fps-320x180.mp4")
    guard FileManager.default.fileExists(atPath: fixture.path) else { return }
    let request = try ThumbnailRequest(
        assetID: UUID(uuidString: "AAAAAAAA-A300-0000-0000-000000000001")!,
        sourceFingerprint: MediaFingerprinter().fingerprint(url: fixture),
        mediaURL: fixture,
        frameRate: try FrameRate(numerator: 24, denominator: 1),
        requestedSourceTime: try MediaTime(value: 1, timescale: 2),
        pixelWidth: 160,
        pixelHeight: 90
    )

    let data = try await AVThumbnailGenerator().generateJPEG(for: request)
    let image = NSImage(data: data)
    #expect(image != nil)
    #expect((image?.size.width ?? 0) <= 160)
    #expect((image?.size.height ?? 0) <= 90)
}

private actor StubThumbnailGenerator: ThumbnailGenerating {
    let data: Data
    let delay: Duration
    private(set) var generationCount = 0

    init(data: Data, delay: Duration) {
        self.data = data
        self.delay = delay
    }

    func generateJPEG(for request: ThumbnailRequest) async throws -> Data {
        generationCount += 1
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        return data
    }
}

private struct FailingThumbnailGenerator: ThumbnailGenerating {
    func generateJPEG(for request: ThumbnailRequest) async throws -> Data {
        throw ThumbnailTestError.unexpectedGeneration
    }
}

private enum ThumbnailTestError: Error {
    case unexpectedGeneration
}

private func makeThumbnailRequest() throws -> ThumbnailRequest {
    try ThumbnailRequest(
        assetID: UUID(uuidString: "BBBBBBBB-A000-0000-0000-000000000002")!,
        sourceFingerprint: MediaFingerprint(fileSize: 10, modificationTimeNanoseconds: 20),
        mediaURL: URL(fileURLWithPath: "/tmp/thumbnail source.mp4"),
        frameRate: FrameRate(numerator: 24, denominator: 1),
        requestedSourceTime: MediaTime(value: 12, timescale: 24),
        pixelWidth: 320,
        pixelHeight: 180
    )
}

private func makeThumbnailTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("frogmouth-thumbnail-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
