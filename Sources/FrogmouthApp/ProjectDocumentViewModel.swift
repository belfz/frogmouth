import AppKit
import FrogmouthCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectDocumentViewModel: ObservableObject {
    struct ImportProgress: Equatable {
        let completed: Int
        let total: Int
        let filename: String
    }

    typealias TrimEdge = TimelineTrimEdge

    struct TrimPreview: Equatable {
        let clipID: TimelineClip.ID
        let originalRange: MediaTimeRange
        var pendingRange: MediaTimeRange
    }

    @Published private(set) var project: ProjectState?
    @Published private(set) var fileURL: URL?
    @Published private(set) var resolvedMediaURLs: [MediaAsset.ID: URL] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var importProgress: ImportProgress?
    @Published private(set) var selectedAssetID: MediaAsset.ID?
    @Published private(set) var selectedClipID: TimelineClip.ID?
    @Published private(set) var playheadFrame: Int64 = 0
    @Published private(set) var playbackLocation: PlaybackLocation?
    @Published private(set) var trimPreview: TrimPreview?
    @Published private(set) var stabilizationStatuses: [TimelineClip.ID: StabilizationStatus] = [:]
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
    private let stabilizationStatusResolver: StabilizationStatusResolver
    let thumbnailService: ThumbnailService
    let playback: PlaybackCoordinator
    private var session: ProjectDocumentSession?
    private var pendingTransition: PendingTransition?
    private var autosaveStatusTask: Task<Void, Never>?
    private var stabilizationStatusTask: Task<Void, Never>?
    private var stabilizationToolRevision: String?
    private var windowCloseCompletion: (() -> Void)?

    init(
        store: ProjectDocumentStore = ProjectDocumentStore(),
        factsInspector: any ProjectMediaFactsInspecting = AVProjectMediaFactsInspector(),
        fingerprinter: any MediaFingerprinting = MediaFingerprinter(),
        stabilizationStatusResolver: StabilizationStatusResolver = StabilizationStatusResolver(),
        thumbnailService: ThumbnailService = ThumbnailService(),
        playback: PlaybackCoordinator = PlaybackCoordinator()
    ) {
        self.store = store
        self.factsInspector = factsInspector
        self.fingerprinter = fingerprinter
        self.stabilizationStatusResolver = stabilizationStatusResolver
        self.thumbnailService = thumbnailService
        self.playback = playback
        playback.playheadDidChange = { [weak self] frame, location in
            self?.playheadFrame = frame
            self?.playbackLocation = location
        }
    }

    var hasProject: Bool { project != nil }
    var canSave: Bool { project != nil && !isBusy }
    var canImport: Bool { project != nil && !isBusy }
    var canEditSelectedClip: Bool {
        selectedClipID != nil && !isBusy && trimPreview == nil
    }
    var canSplitSelectedClip: Bool {
        guard canEditSelectedClip,
              let project,
              let selectedClipID,
              let index = try? TimelineIndex(project: project),
              let entry = index.entry(for: selectedClipID) else { return false }
        return playheadFrame > entry.startFrame
            && playheadFrame < entry.startFrame + entry.durationFrames
    }
    var canExportTimeline: Bool {
        guard !isBusy,
              let project,
              !project.clips.isEmpty,
              (try? TimelineIndex(project: project)) != nil else { return false }
        return project.clips.allSatisfy {
            !stabilizationStatus(for: $0, in: project).blocksExport
        }
    }
    var presentationProject: ProjectState? {
        guard var project else { return nil }
        if let trimPreview,
           let index = project.clips.firstIndex(where: { $0.id == trimPreview.clipID }) {
            project.clips[index].sourceRange = trimPreview.pendingRange
        }
        return project
    }
    var displayName: String {
        guard let project else { return "frogmouth" }
        return hasUnsavedChanges ? "\(project.name) — Edited" : project.name
    }

    func configureStabilizationToolRevision(_ revision: String) {
        guard stabilizationToolRevision != revision else { return }
        stabilizationToolRevision = revision
        scheduleStabilizationStatusRefresh()
    }

    func stabilizationStatus(
        for clip: TimelineClip,
        in project: ProjectState
    ) -> StabilizationStatus {
        guard !clip.stabilizationPasses.isEmpty else { return .none }
        let asset = project.mediaLibrary.first { $0.id == clip.assetID }
        if let coverageStatus = StabilizationStatusResolver.coverageStatus(
            for: clip,
            asset: asset
        ) {
            return coverageStatus
        }
        guard stabilizationToolRevision != nil else {
            return .stale(.validationPending)
        }
        return stabilizationStatuses[clip.id] ?? .stale(.validationPending)
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
        if trimPreview != nil {
            cancelTrimPreview()
            return
        }
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
        if trimPreview != nil {
            cancelTrimPreview()
            return
        }
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
        Task { await importIntoCurrentProject(urls, appendToTimeline: false) }
    }

    func selectAsset(_ assetID: MediaAsset.ID?) {
        cancelTrimPreview()
        selectedAssetID = assetID
        selectedClipID = nil
    }

    func selectClip(_ clipID: TimelineClip.ID?) {
        if trimPreview?.clipID != clipID { cancelTrimPreview() }
        selectedClipID = clipID
        guard let clipID,
              let clip = project?.clips.first(where: { $0.id == clipID }) else { return }
        selectedAssetID = clip.assetID
    }

    func setPlayheadFrame(_ frame: Int64) {
        guard let project, let index = try? TimelineIndex(project: project) else {
            playheadFrame = 0
            playback.seek(toFrame: 0)
            return
        }
        let clamped = min(max(0, frame), index.totalFrames)
        playheadFrame = clamped
        playback.seek(toFrame: clamped)
    }

    func updateTrimPreview(
        clipID: TimelineClip.ID,
        edge: TrimEdge,
        timelineFrameDelta: Int64
    ) {
        guard !isBusy,
              let project,
              let clip = project.clips.first(where: { $0.id == clipID }),
              let asset = project.mediaLibrary.first(where: { $0.id == clip.assetID }),
              let timelineRate = project.timelineFormat?.frameRate else { return }
        if trimPreview?.clipID != clipID {
            trimPreview = TrimPreview(
                clipID: clipID,
                originalRange: clip.sourceRange,
                pendingRange: clip.sourceRange
            )
        }
        guard let original = trimPreview?.originalRange,
              let range = try? TimelineTrimMapper().sourceRange(
                originalRange: original,
                assetDuration: asset.inspected.duration,
                edge: edge,
                timelineFrameDelta: timelineFrameDelta,
                timelineRate: timelineRate,
                sourceRate: asset.inspected.frameRate
              ) else { return }

        var validator = ProjectEditor(project: project)
        guard (try? validator.apply(.trimClip(clipID: clipID, sourceRange: range))) != nil else {
            return
        }
        trimPreview?.pendingRange = range
    }

    func commitTrimPreview() {
        guard let preview = trimPreview, let session else { return }
        isBusy = true
        Task {
            defer {
                trimPreview = nil
                isBusy = false
            }
            do {
                try await session.beginTrim(clipID: preview.clipID)
                try await session.updateTrim(to: preview.pendingRange)
                try await session.commitTrim()
                await refreshPublishedState()
                scheduleAutosaveStatusRefresh()
            } catch {
                errorMessage = error.localizedDescription
                await refreshPublishedState()
            }
        }
    }

    func cancelTrimPreview() {
        trimPreview = nil
    }

    func splitSelectedClip() {
        guard canSplitSelectedClip,
              let session,
              let project,
              let selectedClipID,
              let index = try? TimelineIndex(project: project),
              let entry = index.entry(for: selectedClipID) else { return }
        let rightClipID = UUID()
        let offset = playheadFrame - entry.startFrame
        Task {
            _ = await apply(
                .splitClip(
                    clipID: selectedClipID,
                    atTimelineFrameOffset: offset,
                    rightClipID: rightClipID
                ),
                to: session,
                selectingClip: rightClipID
            )
        }
    }

    func duplicateSelectedClip() {
        guard canEditSelectedClip, let session, let selectedClipID else { return }
        let duplicateID = UUID()
        Task {
            guard await apply(
                .duplicateClip(clipID: selectedClipID, newClipID: duplicateID),
                to: session,
                selectingClip: duplicateID
            ) else { return }
            movePlayheadToSelectedClipStart()
        }
    }

    func deleteSelectedClip() {
        guard canEditSelectedClip,
              let session,
              let project,
              let selectedClipID,
              let deletedIndex = project.clips.firstIndex(where: { $0.id == selectedClipID }) else {
            return
        }
        Task {
            guard await apply(.deleteClip(clipID: selectedClipID), to: session) else {
                return
            }
            guard let updated = self.project else { return }
            if updated.clips.isEmpty {
                self.selectedClipID = nil
                self.setPlayheadFrame(0)
            } else {
                let nextIndex = min(deletedIndex, updated.clips.count - 1)
                self.selectClip(updated.clips[nextIndex].id)
                self.movePlayheadToSelectedClipStart()
            }
        }
    }

    func moveClip(_ clipID: TimelineClip.ID, toBoundaryIndex boundaryIndex: Int) {
        guard !isBusy,
              trimPreview == nil,
              let session,
              let project,
              let sourceIndex = project.clips.firstIndex(where: { $0.id == clipID }),
              !project.clips.isEmpty else { return }
        let destination = sourceIndex < boundaryIndex ? boundaryIndex - 1 : boundaryIndex
        let clamped = min(max(0, destination), project.clips.count - 1)
        guard clamped != sourceIndex else { return }
        Task {
            guard await apply(
                .moveClip(clipID: clipID, toIndex: clamped),
                to: session,
                selectingClip: clipID
            ) else { return }
            movePlayheadToSelectedClipStart()
        }
    }

    func insertAssetOnTimeline(_ assetID: MediaAsset.ID, at index: Int? = nil) {
        guard trimPreview == nil,
              let session,
              let project,
              let asset = project.mediaLibrary.first(where: { $0.id == assetID }) else { return }
        guard let sourceRange = try? MediaTimeRange(
            start: .zero,
            duration: asset.inspected.duration
        ) else { return }
        let clip = TimelineClip(
            assetID: assetID,
            sourceRange: sourceRange
        )
        let command: ProjectCommand
        if let index {
            command = .insertClip(clip, atIndex: index)
        } else {
            command = .appendClip(clip)
        }
        Task { await apply(command, to: session, selectingClip: clip.id) }
    }

    func removeAssetFromLibrary(_ assetID: MediaAsset.ID) {
        guard trimPreview == nil, let session else { return }
        Task {
            await apply(.removeUnusedMedia(assetID: assetID), to: session)
        }
    }

    func resolvedURL(for assetID: MediaAsset.ID) -> URL? {
        resolvedMediaURLs[assetID]
    }

    func shutdown() {
        autosaveStatusTask?.cancel()
        stabilizationStatusTask?.cancel()
        playback.shutdown()
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
                try await importVideos(urls, into: newSession, appendToTimeline: true)
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

    private func importIntoCurrentProject(
        _ urls: [URL],
        appendToTimeline: Bool
    ) async {
        guard let session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await importVideos(
                urls,
                into: session,
                appendToTimeline: appendToTimeline
            )
            await refreshPublishedState()
            scheduleAutosaveStatusRefresh()
        } catch {
            errorMessage = error.localizedDescription
            await refreshPublishedState()
        }
    }

    private func importVideos(
        _ urls: [URL],
        into session: ProjectDocumentSession,
        appendToTimeline: Bool
    ) async throws {
        let current = await session.project
        let commands = try await importCommands(
            for: urls,
            startingFrom: current,
            appendToTimeline: appendToTimeline
        )
        for command in commands {
            try await session.apply(command)
        }
    }

    private func importCommands(
        for urls: [URL],
        startingFrom project: ProjectState,
        appendToTimeline: Bool
    ) async throws -> [ProjectCommand] {
        var validator = ProjectEditor(project: project)
        var commands: [ProjectCommand] = []
        defer { importProgress = nil }

        for (offset, rawURL) in urls.enumerated() {
            let url = rawURL.standardizedFileURL
            importProgress = ImportProgress(
                completed: offset,
                total: urls.count,
                filename: url.lastPathComponent
            )
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

            guard appendToTimeline else { continue }
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
    private func apply(
        _ command: ProjectCommand,
        to session: ProjectDocumentSession,
        selectingClip clipID: TimelineClip.ID? = nil
    ) async -> Bool {
        guard !isBusy else { return false }
        do {
            try await session.apply(command)
            if let clipID { selectedClipID = clipID }
            await refreshPublishedState()
            scheduleAutosaveStatusRefresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            await refreshPublishedState()
            return false
        }
    }

    private func movePlayheadToSelectedClipStart() {
        guard let project,
              let selectedClipID,
              let index = try? TimelineIndex(project: project),
              let entry = index.entry(for: selectedClipID) else { return }
        setPlayheadFrame(entry.startFrame)
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
        stabilizationStatusTask?.cancel()
        trimPreview = nil
        stabilizationStatuses = [:]
        self.session = session
    }

    private func refreshPublishedState() async {
        let previousProject = project
        let previousMediaURLs = resolvedMediaURLs
        guard let session else {
            stabilizationStatusTask?.cancel()
            project = nil
            fileURL = nil
            resolvedMediaURLs = [:]
            hasUnsavedChanges = false
            canUndo = false
            canRedo = false
            playheadFrame = 0
            playbackLocation = nil
            stabilizationStatuses = [:]
            playback.rebuild(project: nil, mediaURLs: [:], preservingFrame: 0)
            return
        }
        project = await session.project
        fileURL = await session.fileURL
        resolvedMediaURLs = await session.resolvedMediaURLs
        hasUnsavedChanges = await session.isModified
        canUndo = await session.canUndo
        canRedo = await session.canRedo
        reconcileSelection()
        if let project, let index = try? TimelineIndex(project: project) {
            playheadFrame = min(max(0, playheadFrame), index.totalFrames)
        } else {
            playheadFrame = 0
        }
        if project != previousProject || resolvedMediaURLs != previousMediaURLs {
            playback.rebuild(
                project: project,
                mediaURLs: resolvedMediaURLs,
                preservingFrame: playheadFrame
            )
        }
        if project != previousProject {
            scheduleStabilizationStatusRefresh()
        }
    }

    private func reconcileSelection() {
        guard let project else {
            selectedAssetID = nil
            selectedClipID = nil
            return
        }
        if let selectedClipID,
           let selectedClip = project.clips.first(where: { $0.id == selectedClipID }) {
            selectedAssetID = selectedClip.assetID
        } else if selectedClipID != nil {
            self.selectedClipID = nil
        }
        if let selectedAssetID,
           !project.mediaLibrary.contains(where: { $0.id == selectedAssetID }) {
            self.selectedAssetID = nil
        }
        if selectedClipID == nil, selectedAssetID == nil {
            if let clip = project.clips.first {
                selectedClipID = clip.id
                selectedAssetID = clip.assetID
            } else {
                selectedAssetID = project.mediaLibrary.first?.id
            }
        }
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

    private func scheduleStabilizationStatusRefresh() {
        stabilizationStatusTask?.cancel()
        guard let project else {
            stabilizationStatuses = [:]
            return
        }

        stabilizationStatuses = Dictionary(uniqueKeysWithValues: project.clips.map { clip in
            let status: StabilizationStatus = clip.stabilizationPasses.isEmpty
                ? .none
                : .stale(.validationPending)
            return (clip.id, status)
        })
        guard let toolRevision = stabilizationToolRevision else { return }

        let resolver = stabilizationStatusResolver
        stabilizationStatusTask = Task { [weak self] in
            let statuses = await resolver.statuses(
                for: project,
                toolRevision: toolRevision
            )
            guard !Task.isCancelled,
                  let self,
                  self.project == project,
                  self.stabilizationToolRevision == toolRevision else { return }
            self.stabilizationStatuses = statuses
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
