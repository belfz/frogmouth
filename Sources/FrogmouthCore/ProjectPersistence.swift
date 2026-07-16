import Darwin
import Foundation

public enum ProjectDocumentError: LocalizedError, Equatable, Sendable {
    case firstSaveLocationRequired
    case readFailed(path: String, reason: String)
    case encodingFailed(String)
    case writeFailed(path: String, errorCode: Int32)
    case saveInProgress

    public var errorDescription: String? {
        switch self {
        case .firstSaveLocationRequired:
            "Choose a location for this untitled project before saving."
        case let .readFailed(path, reason):
            "The project could not be read from \(path): \(reason)"
        case let .encodingFailed(reason):
            "The project could not be encoded as JSON: \(reason)"
        case let .writeFailed(path, errorCode):
            "The project could not be saved to \(path) (system error \(errorCode)). The previous file was left unchanged."
        case .saveInProgress:
            "Wait for the current project save to finish before editing."
        }
    }
}

public protocol ProjectFileWriting: Sendable {
    func write(_ data: Data, atomicallyTo destinationURL: URL) throws
}

public struct AtomicProjectFileWriter: ProjectFileWriting {
    public init() {}

    public func write(_ data: Data, atomicallyTo destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var descriptor: Int32 = -1
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        descriptor = temporaryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }
        guard descriptor >= 0 else {
            throw ProjectDocumentError.writeFailed(
                path: destinationURL.path,
                errorCode: errno
            )
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written
                    )
                    guard result > 0 else {
                        throw ProjectDocumentError.writeFailed(
                            path: destinationURL.path,
                            errorCode: errno
                        )
                    }
                    written += result
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw ProjectDocumentError.writeFailed(
                    path: destinationURL.path,
                    errorCode: errno
                )
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw ProjectDocumentError.writeFailed(
                    path: destinationURL.path,
                    errorCode: errno
                )
            }
            descriptor = -1

            let renameStatus = temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
                destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let temporaryPath, let destinationPath else { return Int32(-1) }
                    return Darwin.rename(temporaryPath, destinationPath)
                }
            }
            guard renameStatus == 0 else {
                throw ProjectDocumentError.writeFailed(
                    path: destinationURL.path,
                    errorCode: errno
                )
            }

            let directoryDescriptor = directoryURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_RDONLY)
            }
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                _ = Darwin.close(directoryDescriptor)
            }
        } catch let error as ProjectDocumentError {
            throw error
        } catch {
            throw ProjectDocumentError.writeFailed(
                path: destinationURL.path,
                errorCode: EIO
            )
        }
    }
}

public struct OpenedProjectDocument: Sendable {
    public let project: ProjectState
    public let resolvedMediaURLs: [MediaAsset.ID: URL]
    public let changedAssetIDs: Set<MediaAsset.ID>
}

public actor ProjectDocumentStore {
    private let codec: ProjectJSONCodec
    private let writer: any ProjectFileWriting
    private let openValidator: ProjectOpenValidator

    public init(
        codec: ProjectJSONCodec = ProjectJSONCodec(),
        writer: any ProjectFileWriting = AtomicProjectFileWriter(),
        openValidator: ProjectOpenValidator = ProjectOpenValidator()
    ) {
        self.codec = codec
        self.writer = writer
        self.openValidator = openValidator
    }

    public func open(url: URL) async throws -> OpenedProjectDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectDocumentError.readFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        let decoded = try codec.decode(data)
        let resolved = try await openValidator.validate(project: decoded, projectURL: url)
        return OpenedProjectDocument(
            project: resolved.project,
            resolvedMediaURLs: resolved.resolvedURLs,
            changedAssetIDs: resolved.changedAssetIDs
        )
    }

    public func save(project: ProjectState, to url: URL) throws {
        let data: Data
        do {
            data = try codec.encode(project)
        } catch {
            throw ProjectDocumentError.encodingFailed(error.localizedDescription)
        }
        try writer.write(data, atomicallyTo: url)
    }
}

public enum ProjectAutosaveResult: Sendable {
    case saved(project: ProjectState, url: URL)
    case failed(project: ProjectState, url: URL, error: ProjectDocumentError)
}

public actor ProjectAutosaveCoordinator {
    public typealias Completion = @Sendable (ProjectAutosaveResult) async -> Void

    private let store: ProjectDocumentStore
    private let delay: Duration
    private var generation: UInt64 = 0
    private var pendingTask: Task<Void, Never>?

    public init(
        store: ProjectDocumentStore,
        delay: Duration = .milliseconds(750)
    ) {
        self.store = store
        self.delay = delay
    }

    public func schedule(
        project: ProjectState,
        url: URL,
        completion: @escaping Completion
    ) {
        generation &+= 1
        let token = generation
        pendingTask?.cancel()
        pendingTask = Task { [weak self, store, delay] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                guard await self?.isCurrent(token) == true else { return }
                do {
                    try await store.save(project: project, to: url)
                    guard await self?.isCurrent(token) == true else { return }
                    await completion(.saved(project: project, url: url))
                } catch let error as ProjectDocumentError {
                    guard await self?.isCurrent(token) == true else { return }
                    await completion(.failed(project: project, url: url, error: error))
                } catch {
                    guard await self?.isCurrent(token) == true else { return }
                    await completion(.failed(
                        project: project,
                        url: url,
                        error: .encodingFailed(error.localizedDescription)
                    ))
                }
                await self?.clearIfCurrent(token)
            } catch {
                // Cancellation is the normal debounce path.
            }
        }
    }

    public func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    public func flush() async {
        let task = pendingTask
        await task?.value
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        generation == token
    }

    private func clearIfCurrent(_ token: UInt64) {
        if generation == token { pendingTask = nil }
    }
}

public actor ProjectDocumentSession {
    private let store: ProjectDocumentStore
    private let autosave: ProjectAutosaveCoordinator
    private var editor: ProjectEditor
    private var lastSavedProject: ProjectState
    private var saveInProgress = false

    public private(set) var fileURL: URL?
    public private(set) var lastSaveError: ProjectDocumentError?
    public private(set) var resolvedMediaURLs: [MediaAsset.ID: URL]

    private init(
        project: ProjectState,
        fileURL: URL?,
        resolvedMediaURLs: [MediaAsset.ID: URL],
        store: ProjectDocumentStore,
        autosaveDelay: Duration
    ) {
        editor = ProjectEditor(project: project)
        lastSavedProject = project
        self.fileURL = fileURL
        self.resolvedMediaURLs = resolvedMediaURLs
        self.store = store
        autosave = ProjectAutosaveCoordinator(store: store, delay: autosaveDelay)
    }

    public static func newProject(
        name: String = "Untitled",
        id: UUID = UUID(),
        store: ProjectDocumentStore = ProjectDocumentStore(),
        autosaveDelay: Duration = .milliseconds(750)
    ) -> ProjectDocumentSession {
        ProjectDocumentSession(
            project: ProjectState(id: id, name: name),
            fileURL: nil,
            resolvedMediaURLs: [:],
            store: store,
            autosaveDelay: autosaveDelay
        )
    }

    public static func open(
        url: URL,
        store: ProjectDocumentStore = ProjectDocumentStore(),
        autosaveDelay: Duration = .milliseconds(750)
    ) async throws -> ProjectDocumentSession {
        let opened = try await store.open(url: url)
        return ProjectDocumentSession(
            project: opened.project,
            fileURL: url,
            resolvedMediaURLs: opened.resolvedMediaURLs,
            store: store,
            autosaveDelay: autosaveDelay
        )
    }

    public var project: ProjectState { editor.project }
    public var isModified: Bool { editor.project != lastSavedProject }
    public var needsCloseConfirmation: Bool { isModified }
    public var canUndo: Bool { editor.history.canUndo }
    public var canRedo: Bool { editor.history.canRedo }
    public var pendingTrim: TrimTransaction? { editor.trimTransaction }

    public func apply(_ command: ProjectCommand) async throws {
        try ensureNotSaving()
        let previous = editor.project
        try editor.apply(command)
        if editor.project != previous {
            reconcileResolvedMediaURLs()
            await scheduleAutosaveIfPossible()
        }
    }

    @discardableResult
    public func undo() async throws -> Bool {
        try ensureNotSaving()
        let changed = try editor.undo()
        if changed {
            reconcileResolvedMediaURLs()
            await scheduleAutosaveIfPossible()
        }
        return changed
    }

    @discardableResult
    public func redo() async throws -> Bool {
        try ensureNotSaving()
        let changed = try editor.redo()
        if changed {
            reconcileResolvedMediaURLs()
            await scheduleAutosaveIfPossible()
        }
        return changed
    }

    public func beginTrim(clipID: TimelineClip.ID) throws {
        try ensureNotSaving()
        try editor.beginTrim(clipID: clipID)
    }

    public func updateTrim(to sourceRange: MediaTimeRange) throws {
        try ensureNotSaving()
        try editor.updateTrim(to: sourceRange)
    }

    public func commitTrim() async throws {
        try ensureNotSaving()
        let previous = editor.project
        try editor.commitTrim()
        if editor.project != previous { await scheduleAutosaveIfPossible() }
    }

    public func cancelTrim() throws {
        try ensureNotSaving()
        try editor.cancelTrim()
    }

    public func save() async throws {
        guard let fileURL else { throw ProjectDocumentError.firstSaveLocationRequired }
        try await saveCurrentProject(to: fileURL, updateLocation: false)
    }

    public func save(to url: URL) async throws {
        try await saveCurrentProject(to: url, updateLocation: true)
    }

    public func saveAs(to url: URL, newProjectID: UUID = UUID()) async throws {
        try ensureNotSaving()
        saveInProgress = true
        defer { saveInProgress = false }
        await autosave.cancel()

        var candidate = editor.project
        candidate.id = newProjectID
        do {
            try await store.save(project: candidate, to: url)
            editor.reassignProjectID(newProjectID)
            fileURL = url
            lastSavedProject = candidate
            lastSaveError = nil
        } catch let error as ProjectDocumentError {
            lastSaveError = error
            throw error
        }
    }

    public func flushAutosave() async {
        await autosave.flush()
    }

    public func discardUnsavedChanges() async {
        await autosave.cancel()
        editor = ProjectEditor(project: lastSavedProject)
        lastSaveError = nil
        reconcileResolvedMediaURLs()
    }

    private func saveCurrentProject(to url: URL, updateLocation: Bool) async throws {
        try ensureNotSaving()
        saveInProgress = true
        defer { saveInProgress = false }
        await autosave.cancel()
        let snapshot = editor.project
        do {
            try await store.save(project: snapshot, to: url)
            if updateLocation { fileURL = url }
            lastSavedProject = snapshot
            lastSaveError = nil
        } catch let error as ProjectDocumentError {
            lastSaveError = error
            throw error
        }
    }

    private func scheduleAutosaveIfPossible() async {
        guard let fileURL else { return }
        let snapshot = editor.project
        await autosave.schedule(project: snapshot, url: fileURL) { [weak self] result in
            await self?.handleAutosaveResult(result)
        }
    }

    private func reconcileResolvedMediaURLs() {
        let assetIDs = Set(editor.project.mediaLibrary.map(\.id))
        resolvedMediaURLs = resolvedMediaURLs.filter { assetIDs.contains($0.key) }
        for asset in editor.project.mediaLibrary where resolvedMediaURLs[asset.id] == nil {
            if let fileURL,
               let resolved = ProjectMediaResolver().resolve(asset.path, projectURL: fileURL) {
                resolvedMediaURLs[asset.id] = resolved
                continue
            }
            let fallback = URL(fileURLWithPath: asset.path.absoluteFallback).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: fallback.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue {
                resolvedMediaURLs[asset.id] = fallback
            }
        }
    }

    private func handleAutosaveResult(_ result: ProjectAutosaveResult) {
        switch result {
        case let .saved(project, url) where url == fileURL:
            lastSavedProject = project
            lastSaveError = nil
        case let .failed(_, url, error) where url == fileURL:
            lastSaveError = error
        case .saved, .failed:
            break
        }
    }

    private func ensureNotSaving() throws {
        if saveInProgress { throw ProjectDocumentError.saveInProgress }
    }
}
