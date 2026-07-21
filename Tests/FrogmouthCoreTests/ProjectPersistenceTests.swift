import Foundation
import Testing

@testable import FrogmouthCore

@Test func documentPublishesAConsistentUIStateInOneSnapshot() async throws {
    let session = ProjectDocumentSession.newProject(name: "Snapshot")
    let asset = try makePersistenceAsset(
        id: UUID(uuidString: "AAAAAAAA-8700-0000-0000-000000000001")!,
        path: "/tmp/snapshot.mp4"
    )
    try await session.apply(.importMedia(asset))

    let state = await session.publishedState
    #expect(state.project.mediaLibrary == [asset])
    #expect(state.fileURL == nil)
    #expect(state.resolvedMediaURLs.isEmpty)
    #expect(state.isModified)
    #expect(state.canUndo)
    #expect(!state.canRedo)
}

@Test func atomicProjectSaveReplacesTheDocumentWithoutLeavingTemporaryFiles() async throws {
    let root = try makePersistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectURL = root.appendingPathComponent("Owls.frogmouth")
    let store = ProjectDocumentStore()
    let first = ProjectState(
        id: UUID(uuidString: "AAAAAAAA-8000-0000-0000-000000000001")!,
        name: "First"
    )
    let second = ProjectState(
        id: UUID(uuidString: "BBBBBBBB-8000-0000-0000-000000000002")!,
        name: "Second"
    )

    try await store.save(project: first, to: projectURL)
    try await store.save(project: second, to: projectURL)

    let saved = try decodeProject(at: projectURL)
    #expect(saved == second)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(siblings == [projectURL.lastPathComponent])
}

@Test func failedSavePreservesTheLastValidFileAndCurrentInMemoryEdits() async throws {
    let root = try makePersistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectURL = root.appendingPathComponent("Kingfisher.frogmouth")
    let original = ProjectState(
        id: UUID(uuidString: "AAAAAAAA-8100-0000-0000-000000000001")!,
        name: "Kingfisher"
    )
    try await ProjectDocumentStore().save(project: original, to: projectURL)
    let originalBytes = try Data(contentsOf: projectURL)

    let failingStore = ProjectDocumentStore(writer: AlwaysFailingProjectWriter())
    let session = try await ProjectDocumentSession.open(
        url: projectURL,
        store: failingStore,
        autosaveDelay: .seconds(60)
    )
    let asset = try makePersistenceAsset(
        id: UUID(uuidString: "BBBBBBBB-8100-0000-0000-000000000002")!,
        path: "/tmp/new edit.mp4"
    )
    try await session.apply(.importMedia(asset))

    do {
        try await session.save()
        Issue.record("Expected the injected writer to fail")
    } catch let error as ProjectDocumentError {
        #expect(error == .writeFailed(path: projectURL.path, errorCode: 5))
    }

    let current = await session.project
    let modified = await session.isModified
    let saveError = await session.lastSaveError
    #expect(current.mediaLibrary == [asset])
    #expect(modified)
    #expect(saveError == .writeFailed(path: projectURL.path, errorCode: 5))
    #expect(try Data(contentsOf: projectURL) == originalBytes)
    #expect(try decodeProject(at: projectURL) == original)
}

@Test func firstSaveSaveAndSaveAsMaintainDocumentIdentityAndCloseState() async throws {
    let root = try makePersistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("Birds.frogmouth")
    let copyURL = root.appendingPathComponent("Birds Copy.frogmouth")
    let originalID = UUID(uuidString: "AAAAAAAA-8200-0000-0000-000000000001")!
    let copyID = UUID(uuidString: "BBBBBBBB-8200-0000-0000-000000000002")!
    let session = ProjectDocumentSession.newProject(
        name: "Birds",
        id: originalID,
        autosaveDelay: .milliseconds(20)
    )
    let initiallyModified = await session.isModified
    let initiallyNeedsConfirmation = await session.needsCloseConfirmation
    #expect(!initiallyModified)
    #expect(!initiallyNeedsConfirmation)

    let asset = try makePersistenceAsset(
        id: UUID(uuidString: "CCCCCCCC-8200-0000-0000-000000000003")!,
        path: "/tmp/bird.mp4"
    )
    try await session.apply(.importMedia(asset))
    let modifiedBeforeSave = await session.isModified
    let needsConfirmationBeforeSave = await session.needsCloseConfirmation
    #expect(modifiedBeforeSave)
    #expect(needsConfirmationBeforeSave)

    do {
        try await session.save()
        Issue.record("Expected an untitled project to require a first-save location")
    } catch let error as ProjectDocumentError {
        #expect(error == .firstSaveLocationRequired)
    }

    try await session.save(to: firstURL)
    let firstLocation = await session.fileURL
    let modifiedAfterSave = await session.isModified
    #expect(firstLocation == firstURL)
    #expect(!modifiedAfterSave)
    #expect(try decodeProject(at: firstURL).id == originalID)

    try await session.saveAs(to: copyURL, newProjectID: copyID)
    let copiedProject = await session.project
    let copiedLocation = await session.fileURL
    #expect(copiedProject.id == copyID)
    #expect(copiedLocation == copyURL)
    #expect(try decodeProject(at: firstURL).id == originalID)
    #expect(try decodeProject(at: copyURL).id == copyID)

    #expect(try await session.undo())
    let undone = await session.project
    #expect(undone.id == copyID)
    #expect(undone.mediaLibrary.isEmpty)
    await session.flushAutosave()
    #expect(try await session.redo())
    await session.flushAutosave()
    let redone = await session.project
    #expect(redone.id == copyID)
    #expect(redone.mediaLibrary == [asset])
}

@Test func rapidCommittedEditsAndHistoryChangesDebounceToValidJSON() async throws {
    let root = try makePersistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectURL = root.appendingPathComponent("Rapid.frogmouth")
    let writer = RecordingProjectWriter()
    let store = ProjectDocumentStore(writer: writer)
    let session = ProjectDocumentSession.newProject(
        name: "Rapid",
        store: store,
        autosaveDelay: .milliseconds(40)
    )
    try await session.save(to: projectURL)

    let assets = try (1...3).map { index in
        try makePersistenceAsset(
            id: UUID(uuidString: "AAAAAAAA-8300-0000-0000-00000000000\(index)")!,
            path: "/tmp/rapid \(index).mp4"
        )
    }
    for asset in assets {
        try await session.apply(.importMedia(asset))
    }
    await session.flushAutosave()

    let afterEdits = await session.project
    #expect(try decodeProject(at: projectURL) == afterEdits)
    #expect(writer.writeCount == 2)

    #expect(try await session.undo())
    await session.flushAutosave()
    let afterUndo = await session.project
    #expect(try decodeProject(at: projectURL) == afterUndo)
    #expect(writer.writeCount == 3)

    #expect(try await session.redo())
    await session.flushAutosave()
    let afterRedo = await session.project
    #expect(try decodeProject(at: projectURL) == afterRedo)
    #expect(writer.writeCount == 4)
}

@Test func trimDragIsNotPersistedUntilTheTrimTransactionCommits() async throws {
    let root = try makePersistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectURL = root.appendingPathComponent("Trim.frogmouth")
    let session = ProjectDocumentSession.newProject(
        name: "Trim",
        autosaveDelay: .milliseconds(20)
    )
    let rate = try FrameRate(numerator: 24, denominator: 1)
    let asset = try makePersistenceAsset(
        id: UUID(uuidString: "AAAAAAAA-8400-0000-0000-000000000001")!,
        path: "/tmp/trim.mp4",
        frameRate: rate,
        frameCount: 96
    )
    let clip = TimelineClip(
        id: UUID(uuidString: "BBBBBBBB-8400-0000-0000-000000000002")!,
        assetID: asset.id,
        sourceRange: try MediaTimeRange(start: .zero, duration: rate.time(forFrame: 96))
    )
    try await session.apply(.importMedia(asset))
    try await session.apply(.appendClip(clip))
    try await session.save(to: projectURL)
    let committedBeforeDrag = try decodeProject(at: projectURL)

    let pendingRange = try MediaTimeRange(
        start: rate.time(forFrame: 12),
        duration: rate.time(forFrame: 60)
    )
    try await session.beginTrim(clipID: clip.id)
    try await session.updateTrim(to: pendingRange)
    await session.flushAutosave()

    #expect(try decodeProject(at: projectURL) == committedBeforeDrag)
    let projectDuringDrag = await session.project
    let pendingTrim = await session.pendingTrim
    #expect(projectDuringDrag.clips[0].sourceRange == clip.sourceRange)
    #expect(pendingTrim?.pendingRange == pendingRange)

    try await session.commitTrim()
    await session.flushAutosave()
    let savedAfterCommit = try decodeProject(at: projectURL)
    #expect(savedAfterCommit.clips[0].sourceRange == pendingRange)
}

@Test func reopeningRestoresTheExactProjectWithoutSessionHistory() async throws {
    let root = try makePersistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mediaURL = root.appendingPathComponent("source.mp4")
    try Data(repeating: 7, count: 32).write(to: mediaURL)
    let projectURL = root.appendingPathComponent("Reopen.frogmouth")
    let asset = try makePersistenceAsset(
        id: UUID(uuidString: "AAAAAAAA-8500-0000-0000-000000000001")!,
        path: mediaURL.path,
        fingerprint: MediaFingerprinter().fingerprint(url: mediaURL)
    )
    let session = ProjectDocumentSession.newProject(name: "Reopen")
    try await session.apply(.importMedia(asset))
    try await session.save(to: projectURL)
    let expected = await session.project
    let originalCanUndo = await session.canUndo
    let importedURLs = await session.resolvedMediaURLs
    #expect(originalCanUndo)
    #expect(importedURLs[asset.id] == mediaURL.standardizedFileURL)

    #expect(try await session.undo())
    let URLsAfterUndo = await session.resolvedMediaURLs
    #expect(URLsAfterUndo.isEmpty)
    #expect(try await session.redo())
    let URLsAfterRedo = await session.resolvedMediaURLs
    #expect(URLsAfterRedo[asset.id] == mediaURL.standardizedFileURL)
    try await session.save()

    let reopened = try await ProjectDocumentSession.open(url: projectURL)
    let reopenedProject = await reopened.project
    let reopenedCanUndo = await reopened.canUndo
    let reopenedCanRedo = await reopened.canRedo
    let reopenedModified = await reopened.isModified
    #expect(reopenedProject == expected)
    #expect(!reopenedCanUndo)
    #expect(!reopenedCanRedo)
    #expect(!reopenedModified)
}

@Test func discardingChangesCancelsPendingAutosaveAndRestoresTheSavedSnapshot() async throws {
    let root = try makePersistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectURL = root.appendingPathComponent("Discard.frogmouth")
    let originalID = UUID(uuidString: "AAAAAAAA-8600-0000-0000-000000000001")!
    let session = ProjectDocumentSession.newProject(
        name: "Discard",
        id: originalID,
        autosaveDelay: .milliseconds(80)
    )
    try await session.save(to: projectURL)
    let original = try decodeProject(at: projectURL)
    let asset = try makePersistenceAsset(
        id: UUID(uuidString: "BBBBBBBB-8600-0000-0000-000000000002")!,
        path: "/tmp/discarded.mp4"
    )
    try await session.apply(.importMedia(asset))

    await session.discardUnsavedChanges()
    try await Task.sleep(for: .milliseconds(120))

    let current = await session.project
    let modified = await session.isModified
    let canUndo = await session.canUndo
    #expect(current == original)
    #expect(!modified)
    #expect(!canUndo)
    #expect(try decodeProject(at: projectURL) == original)
}

private struct AlwaysFailingProjectWriter: ProjectFileWriting {
    func write(_ data: Data, atomicallyTo destinationURL: URL) throws {
        throw ProjectDocumentError.writeFailed(path: destinationURL.path, errorCode: 5)
    }
}

private final class RecordingProjectWriter: ProjectFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedWriteCount = 0
    private let writer = AtomicProjectFileWriter()

    var writeCount: Int {
        lock.withLock { storedWriteCount }
    }

    func write(_ data: Data, atomicallyTo destinationURL: URL) throws {
        try writer.write(data, atomicallyTo: destinationURL)
        lock.withLock { storedWriteCount += 1 }
    }
}

private func makePersistenceTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("frogmouth-project-persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func decodeProject(at url: URL) throws -> ProjectState {
    try ProjectJSONCodec().decode(Data(contentsOf: url))
}

private func makePersistenceAsset(
    id: UUID,
    path: String,
    fingerprint: MediaFingerprint = MediaFingerprint(
        fileSize: 1,
        modificationTimeNanoseconds: 1
    ),
    frameRate: FrameRate = try! FrameRate(numerator: 24, denominator: 1),
    frameCount: Int64 = 48
) throws -> MediaAsset {
    MediaAsset(
        id: id,
        path: MediaPathReference(relativeToProject: nil, absoluteFallback: path),
        fingerprint: fingerprint,
        inspected: PersistedMediaFacts(
            duration: try frameRate.time(forFrame: frameCount),
            width: 3_840,
            height: 2_160,
            frameRate: frameRate,
            videoBitrate: 100_000_000,
            videoCodec: "h264",
            audioCodec: "aac",
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            colour: VideoColourMetadata(
                primaries: "bt709",
                transferFunction: "bt709",
                matrix: "bt709",
                range: "limited"
            )
        )
    )
}
