import Foundation
import Testing

@testable import FrogmouthCore

@Test func cacheKeysAreDeterministicAndIncludeEveryCompatibilityInput() throws {
    let identity = makeCacheIdentity()
    let builder = CacheKeyBuilder()
    let first = try builder.key(for: identity)
    let second = try builder.key(for: identity)
    #expect(first == second)
    #expect(first.count == 64)

    var changedFingerprint = identity
    changedFingerprint.sourceFingerprint.fileSize += 1
    #expect(try builder.key(for: changedFingerprint) != first)

    var changedProcessing = identity
    changedProcessing.processingRevision += 1
    #expect(try builder.key(for: changedProcessing) != first)

    var changedTool = identity
    changedTool.toolRevision = "ffmpeg 8.1.2 / libvidstab 1.2"
    #expect(try builder.key(for: changedTool) != first)

    var reorderedParameters = identity
    reorderedParameters.orderedParameters.reverse()
    #expect(try builder.key(for: reorderedParameters) != first)
}

@Test func cacheLookupValidatesArtifactsAndReportsWhyCompatibleEntriesAreStale() async throws {
    let root = try makeCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectCacheStore(rootURL: root.appendingPathComponent("cache"))
    let projectID = UUID(uuidString: "AAAAAAAA-9000-0000-0000-000000000001")!
    let identity = makeCacheIdentity()
    let data = Data([1, 2, 3, 4])

    let artifact = try await store.store(
        data,
        projectID: projectID,
        identity: identity,
        fileExtension: ".MP4"
    )
    let initialLookup = await store.lookup(projectID: projectID, identity: identity)
    #expect(initialLookup == .hit(artifact))
    #expect(try Data(contentsOf: artifact.url) == data)

    var changedFingerprint = identity
    changedFingerprint.sourceFingerprint.modificationTimeNanoseconds += 1
    let fingerprintLookup = await store.lookup(
        projectID: projectID,
        identity: changedFingerprint
    )
    #expect(fingerprintLookup == .stale(.identityChanged([.sourceFingerprint])))

    var changedProcessing = identity
    changedProcessing.processingRevision += 1
    let processingLookup = await store.lookup(
        projectID: projectID,
        identity: changedProcessing
    )
    #expect(processingLookup == .stale(.identityChanged([.processingRevision])))

    var changedTool = identity
    changedTool.toolRevision = "ffmpeg 8.2.0 / libvidstab 1.2"
    let toolLookup = await store.lookup(projectID: projectID, identity: changedTool)
    #expect(toolLookup == .stale(.identityChanged([.toolRevision])))

    var changedParameters = identity
    changedParameters.orderedParameters.append(.init(name: "zoom", value: "1.05"))
    let parameterLookup = await store.lookup(
        projectID: projectID,
        identity: changedParameters
    )
    #expect(parameterLookup == .stale(.identityChanged([.orderedParameters])))

    try FileManager.default.removeItem(at: artifact.url)
    let missingLookup = await store.lookup(projectID: projectID, identity: identity)
    #expect(missingLookup == .stale(.artifactMissing(artifact.url.path)))

    let replacement = try await store.store(
        data,
        projectID: projectID,
        identity: identity,
        fileExtension: "mp4"
    )
    try Data([9]).write(to: replacement.url)
    let changedSizeLookup = await store.lookup(projectID: projectID, identity: identity)
    #expect(changedSizeLookup == .stale(.artifactByteCountChanged(expected: 4, actual: 1)))
}

@Test func manifestCommitKeepsThePreviousArtifactValidWhenReplacementFails() async throws {
    let root = try makeCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheRoot = root.appendingPathComponent("cache")
    let projectID = UUID(uuidString: "AAAAAAAA-9100-0000-0000-000000000001")!
    let identity = makeCacheIdentity()
    let stableStore = ProjectCacheStore(rootURL: cacheRoot)
    let oldData = Data("old valid cache".utf8)
    _ = try await stableStore.store(
        oldData,
        projectID: projectID,
        identity: identity,
        fileExtension: "trf"
    )

    let interruptedStore = ProjectCacheStore(
        rootURL: cacheRoot,
        writer: FailOnNthProjectWriter(failingCall: 2)
    )
    do {
        _ = try await interruptedStore.store(
            Data("replacement".utf8),
            projectID: projectID,
            identity: identity,
            fileExtension: "trf"
        )
        Issue.record("Expected the manifest write to fail")
    } catch is ProjectCacheError {
        // Expected: the newly written artifact is not committed without its manifest.
    }

    let lookup = await stableStore.lookup(projectID: projectID, identity: identity)
    guard case let .hit(artifact) = lookup else {
        Issue.record("Expected the previous cache entry to remain valid, got \(lookup)")
        return
    }
    #expect(try Data(contentsOf: artifact.url) == oldData)
    let siblings = try FileManager.default.contentsOfDirectory(
        at: artifact.url.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    )
    #expect(siblings.map(\.lastPathComponent).sorted() == [
        artifact.url.lastPathComponent,
        "manifest.json",
    ].sorted())
}

@Test func projectAndGlobalCacheClearsNeverTouchDocumentsOrSourceMedia() async throws {
    let root = try makeCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheRoot = root.appendingPathComponent("managed cache")
    let documentURL = root.appendingPathComponent("Wildlife.frogmouth")
    let mediaURL = root.appendingPathComponent("source.MP4")
    let documentBytes = Data("project document".utf8)
    let mediaBytes = Data("source media".utf8)
    try documentBytes.write(to: documentURL)
    try mediaBytes.write(to: mediaURL)

    let firstProjectID = UUID(uuidString: "AAAAAAAA-9200-0000-0000-000000000001")!
    let secondProjectID = UUID(uuidString: "BBBBBBBB-9200-0000-0000-000000000002")!
    let identity = makeCacheIdentity()
    let store = ProjectCacheStore(rootURL: cacheRoot)
    _ = try await store.store(
        Data([1]),
        projectID: firstProjectID,
        identity: identity,
        fileExtension: "jpg"
    )
    _ = try await store.store(
        Data([2]),
        projectID: secondProjectID,
        identity: identity,
        fileExtension: "jpg"
    )

    try await store.clearProjectCache(projectID: firstProjectID)
    let firstAfterClear = await store.lookup(projectID: firstProjectID, identity: identity)
    let secondAfterProjectClear = await store.lookup(
        projectID: secondProjectID,
        identity: identity
    )
    #expect(firstAfterClear == .stale(.notCached))
    guard case .hit = secondAfterProjectClear else {
        Issue.record("Clearing one project removed another project's cache")
        return
    }
    #expect(try Data(contentsOf: documentURL) == documentBytes)
    #expect(try Data(contentsOf: mediaURL) == mediaBytes)

    try await store.clearAllCaches()
    let secondAfterGlobalClear = await store.lookup(
        projectID: secondProjectID,
        identity: identity
    )
    #expect(secondAfterGlobalClear == .stale(.notCached))
    #expect(try Data(contentsOf: documentURL) == documentBytes)
    #expect(try Data(contentsOf: mediaURL) == mediaBytes)
}

@Test func whollyAbsentCacheIsANormalMissAndInvalidExtensionsAreRejected() async throws {
    let root = try makeCacheTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectCacheStore(rootURL: root.appendingPathComponent("does not exist"))
    let projectID = UUID(uuidString: "AAAAAAAA-9300-0000-0000-000000000001")!
    let identity = makeCacheIdentity()

    let lookup = await store.lookup(projectID: projectID, identity: identity)
    #expect(lookup == .stale(.notCached))

    do {
        _ = try await store.store(
            Data(),
            projectID: projectID,
            identity: identity,
            fileExtension: "../mp4"
        )
        Issue.record("Expected an unsafe extension to be rejected")
    } catch let error as ProjectCacheError {
        #expect(error == .invalidFileExtension("../mp4"))
    }
}

private final class FailOnNthProjectWriter: ProjectFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let failingCall: Int
    private var callCount = 0
    private let writer = AtomicProjectFileWriter()

    init(failingCall: Int) {
        self.failingCall = failingCall
    }

    func write(_ data: Data, atomicallyTo destinationURL: URL) throws {
        let currentCall = lock.withLock {
            callCount += 1
            return callCount
        }
        if currentCall == failingCall {
            throw ProjectDocumentError.writeFailed(path: destinationURL.path, errorCode: 5)
        }
        try writer.write(data, atomicallyTo: destinationURL)
    }
}

private func makeCacheIdentity() -> CacheEntryIdentity {
    CacheEntryIdentity(
        namespace: "stabilization-preview",
        logicalArtifactID: "pass-AAAAAAAA-0000-0000-0000-000000000001",
        assetID: UUID(uuidString: "CCCCCCCC-9000-0000-0000-000000000003")!,
        sourceFingerprint: MediaFingerprint(
            fileSize: 1_234_567,
            modificationTimeNanoseconds: 1_785_000_000_000_000_000
        ),
        processingRevision: 3,
        toolRevision: "ffmpeg 8.1.1 / libvidstab 1.1",
        orderedParameters: [
            CacheKeyComponent(name: "analysis-range", value: "120/24...480/24"),
            CacheKeyComponent(name: "preceding-pass", value: "none"),
            CacheKeyComponent(name: "profile", value: "handheld-shake"),
            CacheKeyComponent(name: "proxy-width", value: "1024"),
        ]
    )
}

private func makeCacheTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("frogmouth-project-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
