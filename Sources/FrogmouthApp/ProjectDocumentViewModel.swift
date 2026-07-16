import AppKit
import FrogmouthCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectDocumentViewModel: ObservableObject {
    @Published private(set) var project: ProjectState?
    @Published private(set) var fileURL: URL?
    @Published private(set) var resolvedMediaURLs: [MediaAsset.ID: URL] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var errorMessage: String?
    @Published var isUnsavedConfirmationPresented = false

    private enum PendingTransition {
        case newProject
        case openProject(URL)
        case importAsNewProject([URL])
        case closeProject
    }

    private let store: ProjectDocumentStore
    private let factsInspector: any ProjectMediaFactsInspecting
    private let fingerprinter: any MediaFingerprinting
    private var session: ProjectDocumentSession?
    private var pendingTransition: PendingTransition?
    private var autosaveStatusTask: Task<Void, Never>?
    private var windowCloseCompletion: (() -> Void)?

    init(
        store: ProjectDocumentStore = ProjectDocumentStore(),
        factsInspector: any ProjectMediaFactsInspecting = AVProjectMediaFactsInspector(),
        fingerprinter: any MediaFingerprinting = MediaFingerprinter()
    ) {
        self.store = store
        self.factsInspector = factsInspector
        self.fingerprinter = fingerprinter
    }

    var hasProject: Bool { project != nil }
    var canSave: Bool { project != nil && !isBusy }
    var canImport: Bool { project != nil && !isBusy }
    var displayName: String {
        guard let project else { return "frogmouth" }
        return hasUnsavedChanges ? "\(project.name) — Edited" : project.name
    }

    func requestNewProject() {
        request(.newProject)
    }

    func presentOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.frogmouthProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Open a frogmouth project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        request(.openProject(url))
    }

    func presentImportVideosPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = hasProject
            ? "Import videos into the current project"
            : "Create a project from one or more videos"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importVideos(panel.urls)
    }

    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let standardized = urls.map(\.standardizedFileURL)
        if standardized.count == 1,
           standardized[0].pathExtension.lowercased() == "frogmouth" {
            request(.openProject(standardized[0]))
            return true
        }
        guard standardized.allSatisfy(Self.isMovieURL) else {
            errorMessage = "Drop one .frogmouth project or one or more video files."
            return false
        }
        importVideos(standardized)
        return true
    }

    func openExternalURL(_ url: URL) {
        if url.pathExtension.lowercased() == "frogmouth" {
            request(.openProject(url))
        } else if Self.isMovieURL(url) {
            importVideos([url])
        }
    }

    func requestCloseProject() {
        guard hasProject else { return }
        request(.closeProject)
    }

    func requestWindowClose(whenApproved completion: @escaping () -> Void) {
        guard hasUnsavedChanges else {
            completion()
            return
        }
        windowCloseCompletion = completion
        request(.closeProject)
    }

    func save() {
        Task { _ = await saveCurrentProject(chooseLocationWhenNeeded: true) }
    }

    func saveAs() {
        guard session != nil, !isBusy, let destination = chooseSaveLocation() else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await session?.saveAs(to: destination)
                await refreshPublishedState()
            } catch {
                errorMessage = error.localizedDescription
                await refreshPublishedState()
            }
        }
    }

    func undo() {
        guard !isBusy, let session else { return }
        Task {
            do {
                _ = try await session.undo()
                await refreshPublishedState()
                scheduleAutosaveStatusRefresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func redo() {
        guard !isBusy, let session else { return }
        Task {
            do {
                _ = try await session.redo()
                await refreshPublishedState()
                scheduleAutosaveStatusRefresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resolveUnsavedChangesBySaving() {
        isUnsavedConfirmationPresented = false
        Task {
            guard await saveCurrentProject(chooseLocationWhenNeeded: true) else {
                pendingTransition = nil
                windowCloseCompletion = nil
                return
            }
            await performPendingTransition()
        }
    }

    func resolveUnsavedChangesByDiscarding() {
        isUnsavedConfirmationPresented = false
        Task {
            await session?.discardUnsavedChanges()
            await refreshPublishedState()
            await performPendingTransition()
        }
    }

    func cancelPendingTransition() {
        pendingTransition = nil
        windowCloseCompletion = nil
        isUnsavedConfirmationPresented = false
    }

    func importVideos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if session == nil {
            request(.importAsNewProject(urls))
            return
        }
        Task { await importIntoCurrentProject(urls) }
    }

    func resolvedURL(for assetID: MediaAsset.ID) -> URL? {
        resolvedMediaURLs[assetID]
    }

    func shutdown() {
        autosaveStatusTask?.cancel()
    }

    private func request(_ transition: PendingTransition) {
        guard !isBusy else { return }
        if hasUnsavedChanges {
            pendingTransition = transition
            isUnsavedConfirmationPresented = true
        } else {
            pendingTransition = transition
            Task { await performPendingTransition() }
        }
    }

    private func performPendingTransition() async {
        guard let transition = pendingTransition else { return }
        pendingTransition = nil
        isBusy = true
        defer { isBusy = false }

        do {
            switch transition {
            case .newProject:
                install(ProjectDocumentSession.newProject())
                await refreshPublishedState()
            case let .openProject(url):
                let opened = try await ProjectDocumentSession.open(url: url, store: store)
                install(opened)
                await refreshPublishedState()
            case let .importAsNewProject(urls):
                let newSession = ProjectDocumentSession.newProject(store: store)
                try await importVideos(urls, into: newSession)
                install(newSession)
                await refreshPublishedState()
                scheduleAutosaveStatusRefresh()
            case .closeProject:
                install(nil)
                await refreshPublishedState()
                let completion = windowCloseCompletion
                windowCloseCompletion = nil
                completion?()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importIntoCurrentProject(_ urls: [URL]) async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await importVideos(urls, into: session)
            await refreshPublishedState()
            scheduleAutosaveStatusRefresh()
        } catch {
            errorMessage = error.localizedDescription
            await refreshPublishedState()
        }
    }

    private func importVideos(
        _ urls: [URL],
        into session: ProjectDocumentSession
    ) async throws {
        let current = await session.project
        let commands = try await importCommands(for: urls, startingFrom: current)
        for command in commands {
            try await session.apply(command)
        }
    }

    private func importCommands(
        for urls: [URL],
        startingFrom project: ProjectState
    ) async throws -> [ProjectCommand] {
        var validator = ProjectEditor(project: project)
        var commands: [ProjectCommand] = []

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            let existing = validator.project.mediaLibrary.first { asset in
                URL(fileURLWithPath: asset.path.absoluteFallback).standardizedFileURL == url
            }
            let asset: MediaAsset
            if let existing {
                asset = existing
            } else {
                let facts = try await factsInspector.inspect(url: url)
                asset = MediaAsset(
                    path: MediaPathReference(relativeToProject: nil, absoluteFallback: url.path),
                    fingerprint: try fingerprinter.fingerprint(url: url),
                    inspected: facts
                )
                let command = ProjectCommand.importMedia(asset)
                try validator.apply(command)
                commands.append(command)
            }

            let clip = TimelineClip(
                assetID: asset.id,
                sourceRange: try MediaTimeRange(start: .zero, duration: asset.inspected.duration)
            )
            let command = ProjectCommand.appendClip(clip)
            try validator.apply(command)
            commands.append(command)
        }
        return commands
    }

    @discardableResult
    private func saveCurrentProject(chooseLocationWhenNeeded: Bool) async -> Bool {
        guard let session, !isBusy else { return false }
        let currentURL = await session.fileURL
        let destination: URL?
        if currentURL == nil, chooseLocationWhenNeeded {
            destination = chooseSaveLocation()
            guard destination != nil else { return false }
        } else {
            destination = currentURL
        }

        isBusy = true
        defer { isBusy = false }
        do {
            if let destination, currentURL == nil {
                try await session.save(to: destination)
            } else {
                try await session.save()
            }
            await refreshPublishedState()
            return true
        } catch {
            errorMessage = error.localizedDescription
            await refreshPublishedState()
            return false
        }
    }

    private func chooseSaveLocation() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.frogmouthProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.safeProjectFilename(project?.name ?? "Untitled")
            + ".frogmouth"
        panel.message = "Save a lightweight frogmouth project"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func install(_ session: ProjectDocumentSession?) {
        autosaveStatusTask?.cancel()
        self.session = session
    }

    private func refreshPublishedState() async {
        guard let session else {
            project = nil
            fileURL = nil
            resolvedMediaURLs = [:]
            hasUnsavedChanges = false
            canUndo = false
            canRedo = false
            return
        }
        project = await session.project
        fileURL = await session.fileURL
        resolvedMediaURLs = await session.resolvedMediaURLs
        hasUnsavedChanges = await session.isModified
        canUndo = await session.canUndo
        canRedo = await session.canRedo
    }

    private func scheduleAutosaveStatusRefresh() {
        autosaveStatusTask?.cancel()
        guard fileURL != nil else { return }
        autosaveStatusTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
                guard let self, let session = self.session else { return }
                await session.flushAutosave()
                await self.refreshPublishedState()
            } catch {
                // A newer edit replaced this refresh.
            }
        }
    }

    private static func isMovieURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    private static func safeProjectFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = name.components(separatedBy: invalid).filter { !$0.isEmpty }
        return components.joined(separator: "-").isEmpty ? "Untitled" : components.joined(separator: "-")
    }
}

private extension UTType {
    static let frogmouthProject = UTType(exportedAs: "dev.frogmouth.project", conformingTo: .json)
}
