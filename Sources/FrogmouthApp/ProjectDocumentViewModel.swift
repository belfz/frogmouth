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
    @Published private(set) var stabilizationProcessingPhase: ProcessingPhase = .idle
    @Published private(set) var timelineExportProcessingPhase: ProcessingPhase = .idle
    @Published private(set) var isCheckingTimelineExportReadiness = false
    @Published private(set) var timelineExportReadinessError: TimelineExportReadinessError?
    @Published private(set) var lastExportURL: URL?
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
    private let stabilizationProcessor: ClipStabilizationProcessor
    private let timelineExporter: TimelineExporter
    private let diagnostics: DiagnosticLogStore
    let thumbnailService: ThumbnailService
    let playback: PlaybackCoordinator
    private var session: ProjectDocumentSession?
    private var pendingTransition: PendingTransition?
    private var autosaveStatusTask: Task<Void, Never>?
    private var stabilizationStatusTask: Task<Void, Never>?
    private var stabilizationProcessingTask: Task<Void, Never>?
    private var stabilizationProcessingGeneration = UUID()
    private var timelineExportTask: Task<Void, Never>?
    private var timelineExportReadinessTask: Task<Void, Never>?
    private var timelineExportReadinessGeneration = UUID()
    private var stabilizationValidations: [TimelineClip.ID: StabilizationValidation] = [:]
    private var ffmpegInstallation: FFmpegInstallation?
    private var windowCloseCompletion: (() -> Void)?

    init(
        store: ProjectDocumentStore = ProjectDocumentStore(),
        factsInspector: any ProjectMediaFactsInspecting = AVProjectMediaFactsInspector(),
        fingerprinter: any MediaFingerprinting = MediaFingerprinter(),
        stabilizationStatusResolver: StabilizationStatusResolver? = nil,
        thumbnailService: ThumbnailService? = nil,
        playback: PlaybackCoordinator? = nil,
        diagnostics: DiagnosticLogStore = DiagnosticLogStore(),
        stabilizationProcessor: ClipStabilizationProcessor? = nil,
        timelineExporter: TimelineExporter? = nil
    ) {
        self.store = store
        self.factsInspector = factsInspector
        self.fingerprinter = fingerprinter
        let resolver = stabilizationStatusResolver ?? StabilizationStatusResolver(
            cacheStore: ProjectCacheStore(diagnostics: diagnostics)
        )
        self.stabilizationStatusResolver = resolver
        self.stabilizationProcessor = stabilizationProcessor ?? ClipStabilizationProcessor(
            cacheStore: resolver.cacheStore,
            identityBuilder: resolver.identityBuilder,
            runner: FFmpegRunner(diagnostics: diagnostics)
        )
        self.timelineExporter = timelineExporter ?? TimelineExporter(
            runner: FFmpegRunner(diagnostics: diagnostics),
            diagnostics: diagnostics
        )
        self.diagnostics = diagnostics
        self.thumbnailService = thumbnailService ?? ThumbnailService(cacheStore: resolver.cacheStore)
        let playbackCoordinator = playback ?? PlaybackCoordinator(diagnostics: diagnostics)
        self.playback = playbackCoordinator
        playbackCoordinator.playheadDidChange = { [weak self] frame, location in
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
        !isBusy
            && trimPreview == nil
            && !isCheckingTimelineExportReadiness
            && ffmpegInstallation != nil
            && project?.clips.isEmpty == false
            && timelineExportReadinessError == nil
    }
    var canRequestTimelineExport: Bool {
        !isBusy
            && trimPreview == nil
            && project?.clips.isEmpty == false
    }
    var canRevealExport: Bool { lastExportURL != nil }
    var canApplySelectedStabilization: Bool {
        guard canEditSelectedClip,
              ffmpegInstallation != nil,
              let project,
              let selectedClipID,
              let clip = project.clips.first(where: { $0.id == selectedClipID }) else { return false }
        if case .stale = stabilizationStatus(for: clip, in: project) { return false }
        return true
    }
    var canUpdateSelectedStabilization: Bool {
        guard canEditSelectedClip,
              ffmpegInstallation != nil,
              let project,
              let selectedClipID,
              let clip = project.clips.first(where: { $0.id == selectedClipID }) else { return false }
        return switch stabilizationStatus(for: clip, in: project) {
        case .stale(.validationPending): false
        case .stale: true
        case .none, .valid: false
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

    func configureFFmpegInstallation(_ installation: FFmpegInstallation) {
        guard ffmpegInstallation != installation else { return }
        ffmpegInstallation = installation
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
        guard ffmpegInstallation != nil else {
            return .stale(.validationPending)
        }
        return stabilizationStatuses[clip.id] ?? .stale(.validationPending)
    }

    func applyStabilization(_ mode: StabilizationMode) {
        guard mode != .none,
              canApplySelectedStabilization,
              let project,
              let selectedClipID,
              let clip = project.clips.first(where: { $0.id == selectedClipID }) else { return }
        guard let passes = StabilizationPassPlanner.appending(mode: mode, to: clip) else { return }
        startStabilizationProcessing(clipID: clip.id, passes: passes)
    }

    func updateSelectedStabilization() {
        guard canUpdateSelectedStabilization,
              let project,
              let selectedClipID,
              let clip = project.clips.first(where: { $0.id == selectedClipID }) else { return }
        let passes: [StabilizationEffect]
        do {
            passes = try StabilizationPassPlanner.updating(clip)
        } catch {
            report(error, phase: "stabilization-plan")
            return
        }
        startStabilizationProcessing(clipID: clip.id, passes: passes)
    }

    func cancelStabilizationProcessing() {
        diagnostics.append(
            level: "INFO",
            sessionID: project?.id.uuidString ?? "app",
            phase: "stabilization-processing",
            event: "operation.cancel-requested"
        )
        stabilizationProcessingTask?.cancel()
        stabilizationProcessor.cancel()
    }

    func presentTimelineExportPanel() {
        guard canRequestTimelineExport, let project else { return }
        if isCheckingTimelineExportReadiness {
            report(TimelineExportReadinessError.validationInProgress, phase: "timeline-export-readiness")
            return
        }
        if let error = timelineExportReadinessError {
            report(error, phase: "timeline-export-readiness")
            return
        }
        guard let suggestion = TimelineExportDestinationPolicy.suggestion(
                  project: project,
                  projectFileURL: fileURL,
                  mediaURLs: resolvedMediaURLs
              ) else {
            report(
                TimelineExportReadinessError.invalidTimeline(
                    "frogmouth could not choose an export destination."
                ),
                phase: "timeline-export-readiness"
            )
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = suggestion.directoryURL
        panel.nameFieldStringValue = suggestion.filename
        panel.message = "Export the complete timeline as a high-quality HEVC video"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        startTimelineExport(to: destination)
    }

    func cancelTimelineExport() {
        diagnostics.append(
            level: "INFO",
            sessionID: project?.id.uuidString ?? "app",
            phase: "timeline-export",
            event: "operation.cancel-requested"
        )
        timelineExportTask?.cancel()
        timelineExporter.cancel()
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
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
                logProjectSaved(to: destination, kind: "save-as")
            } catch {
                report(error, phase: "project-save")
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
                diagnostics.append(
                    level: "INFO",
                    sessionID: project?.id.uuidString ?? "app",
                    phase: "project-undo",
                    event: "project.history",
                    fields: ["action": "undo"]
                )
                await refreshPublishedState()
                scheduleAutosaveStatusRefresh()
            } catch {
                report(error, phase: "project-undo")
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
                diagnostics.append(
                    level: "INFO",
                    sessionID: project?.id.uuidString ?? "app",
                    phase: "project-redo",
                    event: "project.history",
                    fields: ["action": "redo"]
                )
                await refreshPublishedState()
                scheduleAutosaveStatusRefresh()
            } catch {
                report(error, phase: "project-redo")
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
                diagnostics.append(
                    level: "INFO",
                    sessionID: project?.id.uuidString ?? "app",
                    phase: "project-trim",
                    event: "project.command",
                    fields: [
                        "command": "trim-clip",
                        "clip_id": preview.clipID.uuidString,
                        "source_range": preview.pendingRange.diagnosticDescription,
                    ]
                )
                try await session.beginTrim(clipID: preview.clipID)
                try await session.updateTrim(to: preview.pendingRange)
                try await session.commitTrim()
                await refreshPublishedState()
                scheduleAutosaveStatusRefresh()
            } catch {
                report(error, phase: "project-trim")
                await refreshPublishedState()
            }
        }
    }

    func adjustTrimByOneTimelineFrame(clipID: TimelineClip.ID, edge: TrimEdge, delta: Int64) {
        guard delta == -1 || delta == 1 else { return }
        updateTrimPreview(
            clipID: clipID,
            edge: edge,
            timelineFrameDelta: delta
        )
        commitTrimPreview()
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

    func enableSelectedVideoFade(at edge: VideoFadeEdge) {
        guard canEditSelectedClip,
              let project,
              let selectedClipID,
              let clip = project.clips.first(where: { $0.id == selectedClipID }),
              let entry = try? TimelineIndex(project: project).entry(for: selectedClipID) else {
            return
        }
        do {
            let fade = try VideoFadePolicy.defaultFade(
                at: edge,
                for: clip,
                timelineDuration: entry.timelineRange.duration
            )
            setSelectedVideoFade(fade, at: edge)
        } catch {
            report(error, phase: "video-fade")
        }
    }

    func commitSelectedVideoFadeDuration(_ value: String, at edge: VideoFadeEdge) {
        guard canEditSelectedClip, let selectedClipID else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = Int64(trimmed) else {
            report(
                TimelineEditError.invalidVideoFadeInput(
                    clipID: selectedClipID,
                    edge: edge,
                    value: value
                ),
                phase: "video-fade"
            )
            return
        }
        setSelectedVideoFade(VideoFade(durationMilliseconds: duration), at: edge)
    }

    func removeSelectedVideoFade(at edge: VideoFadeEdge) {
        setSelectedVideoFade(nil, at: edge)
    }

    private func setSelectedVideoFade(_ fade: VideoFade?, at edge: VideoFadeEdge) {
        guard canEditSelectedClip, let session, let selectedClipID else { return }
        Task {
            await apply(
                .setVideoFade(clipID: selectedClipID, edge: edge, fade: fade),
                to: session,
                selectingClip: selectedClipID
            )
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
        stabilizationProcessingTask?.cancel()
        timelineExportTask?.cancel()
        timelineExportReadinessTask?.cancel()
        stabilizationProcessor.cancel()
        timelineExporter.cancel()
        playback.shutdown()
    }

    private func startTimelineExport(to destination: URL) {
        guard timelineExportTask == nil,
              canExportTimeline,
              let project,
              let installation = ffmpegInstallation else { return }

        let transforms: [TimelineClip.ID: [StabilizationEffect.ID: URL]]
        do {
            transforms = try stabilizationTransforms(for: project)
        } catch {
            report(error, phase: "timeline-export")
            return
        }

        let exporter = timelineExporter
        let request = TimelineExportRequest(
            renderRequest: TimelineRenderRequest(
                project: project,
                mediaURLs: resolvedMediaURLs,
                stabilizationTransforms: transforms
            ),
            destinationURL: destination,
            installation: installation,
            sessionID: project.id.uuidString
        )
        isBusy = true
        timelineExportProcessingPhase = .exporting(progress: 0)
        diagnostics.append(
            level: "INFO",
            sessionID: project.id.uuidString,
            phase: "timeline-export",
            event: "operation.started",
            fields: ["destination_path": destination.path]
        )
        timelineExportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.timelineExportTask = nil
                self.timelineExportProcessingPhase = .idle
                self.isBusy = false
            }
            do {
                let result = try await exporter.export(request) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard self?.timelineExportTask != nil else { return }
                        self?.timelineExportProcessingPhase = .exporting(progress: progress)
                    }
                }
                try Task.checkCancellation()
                self.lastExportURL = result.destinationURL
                self.diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "timeline-export",
                    message: "completed output=\(result.destinationURL.path)"
                )
                NSWorkspace.shared.activateFileViewerSelecting([result.destinationURL])
            } catch is CancellationError {
                // A cancelled export never installs its temporary file.
                self.diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "timeline-export",
                    event: "operation.cancelled"
                )
            } catch let error as FrogmouthError where error == .cancelled {
                // FFmpeg reports user cancellation as a domain error.
                self.diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "timeline-export",
                    event: "operation.cancelled"
                )
            } catch {
                self.report(error, phase: "timeline-export")
            }
        }
    }

    private func stabilizationTransforms(
        for project: ProjectState
    ) throws -> [TimelineClip.ID: [StabilizationEffect.ID: URL]] {
        var result: [TimelineClip.ID: [StabilizationEffect.ID: URL]] = [:]
        for clip in project.clips where !clip.stabilizationPasses.isEmpty {
            guard let validation = stabilizationValidations[clip.id],
                  validation.status == .valid else {
                throw TimelineRenderPlanningError.missingStabilizationTransforms(
                    clip.stabilizationPasses[0].id
                )
            }
            let transforms = Dictionary(uniqueKeysWithValues: validation.artifacts.map {
                ($0.effectID, $0.transforms.url)
            })
            for effect in clip.stabilizationPasses where transforms[effect.id] == nil {
                throw TimelineRenderPlanningError.missingStabilizationTransforms(effect.id)
            }
            result[clip.id] = transforms
        }
        return result
    }

    private func startStabilizationProcessing(
        clipID: TimelineClip.ID,
        passes: [StabilizationEffect]
    ) {
        guard stabilizationProcessingTask == nil,
              let project,
              let session,
              let installation = ffmpegInstallation else { return }
        isBusy = true
        stabilizationProcessingPhase = .analyzing(progress: 0)
        stabilizationProcessingGeneration = UUID()
        let generation = stabilizationProcessingGeneration
        let processor = stabilizationProcessor
        let sourceURLs = resolvedMediaURLs

        stabilizationProcessingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.stabilizationProcessingGeneration == generation {
                    self.stabilizationProcessingTask = nil
                    self.stabilizationProcessingPhase = .idle
                    self.isBusy = false
                }
            }
            do {
                self.diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "stabilization-processing",
                    event: "operation.started",
                    fields: [
                        "clip_id": clipID.uuidString,
                        "pass_count": String(passes.count),
                        "effect_ids": passes.map { $0.id.uuidString }.joined(separator: ","),
                    ]
                )
                let result = try await processor.process(
                    project: project,
                    clipID: clipID,
                    passes: passes,
                    sourceURLs: sourceURLs,
                    installation: installation
                ) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.stabilizationProcessingGeneration == generation,
                              self.stabilizationProcessingTask != nil else { return }
                        switch update.phase {
                        case .analyzing:
                            self.stabilizationProcessingPhase = .analyzing(
                                progress: update.fraction
                            )
                        case .renderingPreview:
                            self.stabilizationProcessingPhase = .renderingPreview(
                                progress: update.fraction
                            )
                        }
                    }
                }
                try Task.checkCancellation()
                guard self.project == project else { throw CancellationError() }
                try await session.apply(.setStabilizationPasses(
                    clipID: clipID,
                    passes: result.passes
                ))
                await self.refreshPublishedState()
                self.scheduleAutosaveStatusRefresh()
                self.diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "stabilization-processing",
                    event: "operation.completed",
                    fields: ["clip_id": clipID.uuidString]
                )
            } catch is CancellationError {
                // Cancellation deliberately leaves the project decision unchanged.
                self.diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "stabilization-processing",
                    event: "operation.cancelled",
                    fields: ["clip_id": clipID.uuidString]
                )
            } catch FrogmouthError.cancelled {
                // FFmpeg cancellation is an expected user action.
                self.diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "stabilization-processing",
                    event: "operation.cancelled",
                    fields: ["clip_id": clipID.uuidString]
                )
            } catch {
                self.report(error, phase: "stabilization-processing")
                await self.refreshPublishedState()
            }
        }
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
                diagnostics.append(
                    level: "INFO",
                    sessionID: "app",
                    phase: "project-lifecycle",
                    event: "project.new"
                )
                install(ProjectDocumentSession.newProject())
                await refreshPublishedState()
            case let .openProject(url):
                diagnostics.append(
                    level: "INFO",
                    sessionID: "app",
                    phase: "project-lifecycle",
                    event: "project.open",
                    fields: ["project_path": url.path]
                )
                let opened = try await ProjectDocumentSession.open(url: url, store: store)
                install(opened)
                await refreshPublishedState()
            case let .importAsNewProject(urls):
                diagnostics.append(
                    level: "INFO",
                    sessionID: "app",
                    phase: "project-lifecycle",
                    event: "project.new-from-media",
                    fields: ["source_paths": urls.map(\.path).joined(separator: " | ")]
                )
                let newSession = ProjectDocumentSession.newProject(store: store)
                try await importVideos(urls, into: newSession, appendToTimeline: true)
                install(newSession)
                await refreshPublishedState()
                scheduleAutosaveStatusRefresh()
            case .closeProject:
                diagnostics.append(
                    level: "INFO",
                    sessionID: project?.id.uuidString ?? "app",
                    phase: "project-lifecycle",
                    event: "project.close",
                    fields: ["project_path": fileURL?.path ?? "<unsaved>"]
                )
                install(nil)
                await refreshPublishedState()
                let completion = windowCloseCompletion
                windowCloseCompletion = nil
                completion?()
            }
        } catch {
            report(error, phase: "project-lifecycle")
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
            report(error, phase: "media-import")
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
                let fingerprinter = self.fingerprinter
                let fingerprint = try await Task.detached(priority: .utility) {
                    try fingerprinter.fingerprint(url: url)
                }.value
                asset = MediaAsset(
                    path: MediaPathReference(relativeToProject: nil, absoluteFallback: url.path),
                    fingerprint: fingerprint,
                    inspected: facts
                )
                let command = ProjectCommand.importMedia(asset)
                try validator.apply(command)
                commands.append(command)
                diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "media-import",
                    event: "media.inspected",
                    fields: command.diagnosticFields.merging([
                        "duration": facts.duration.diagnosticRational,
                        "dimensions": "\(facts.width)x\(facts.height)",
                        "frame_rate": facts.frameRate.diagnosticRational,
                        "colour": facts.colour.diagnosticDescription,
                    ]) { _, new in new }
                )
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
            diagnostics.append(
                level: "INFO",
                sessionID: project?.id.uuidString ?? "app",
                phase: "project-edit",
                event: "project.command",
                fields: command.diagnosticFields.merging([
                    "command": command.diagnosticName,
                ]) { _, new in new }
            )
            try await session.apply(command)
            if let clipID { selectedClipID = clipID }
            await refreshPublishedState()
            scheduleAutosaveStatusRefresh()
            return true
        } catch {
            report(error, phase: "project-edit")
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
            if let savedURL = fileURL ?? destination ?? currentURL {
                logProjectSaved(
                    to: savedURL,
                    kind: currentURL == nil ? "first-save" : "save"
                )
            }
            return true
        } catch {
            report(error, phase: "project-save")
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
        stabilizationValidations = [:]
        lastExportURL = nil
        self.session = session
    }

    private func refreshPublishedState() async {
        let previousProject = project
        let previousFileURL = fileURL
        let previousMediaURLs = resolvedMediaURLs
        guard let session else {
            stabilizationStatusTask?.cancel()
            timelineExportReadinessTask?.cancel()
            project = nil
            fileURL = nil
            resolvedMediaURLs = [:]
            hasUnsavedChanges = false
            canUndo = false
            canRedo = false
            playheadFrame = 0
            playbackLocation = nil
            stabilizationStatuses = [:]
            stabilizationValidations = [:]
            timelineExportReadinessError = .invalidTimeline("No project is open.")
            isCheckingTimelineExportReadiness = false
            playback.rebuild(project: nil, mediaURLs: [:], preservingFrame: 0)
            return
        }
        let state = await session.publishedState
        project = state.project
        fileURL = state.fileURL
        resolvedMediaURLs = state.resolvedMediaURLs
        hasUnsavedChanges = state.isModified
        canUndo = state.canUndo
        canRedo = state.canRedo
        if let project,
           project != previousProject || fileURL != previousFileURL || resolvedMediaURLs != previousMediaURLs {
            diagnostics.appendProjectSnapshot(
                project,
                fileURL: fileURL,
                resolvedMediaURLs: resolvedMediaURLs
            )
        }
        reconcileSelection()
        if let project, let index = try? TimelineIndex(project: project) {
            playheadFrame = min(max(0, playheadFrame), index.totalFrames)
        } else {
            playheadFrame = 0
        }
        let changesOnlyVideoFades = Self.changesOnlyVideoFades(
            from: previousProject,
            to: project
        )
        if project != previousProject || resolvedMediaURLs != previousMediaURLs {
            if changesOnlyVideoFades {
                rebuildPlaybackWithValidatedStabilization()
            } else {
                stabilizationValidations = [:]
                playback.rebuild(
                    project: project,
                    mediaURLs: resolvedMediaURLs,
                    preservingFrame: playheadFrame
                )
            }
        }
        if project != previousProject {
            if changesOnlyVideoFades {
                scheduleTimelineExportReadinessRefresh()
            } else {
                scheduleStabilizationStatusRefresh()
            }
        } else if resolvedMediaURLs != previousMediaURLs {
            scheduleTimelineExportReadinessRefresh()
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
                if let error = await session.lastSaveError {
                    self.report(error, phase: "project-autosave")
                } else if let project = self.project, let fileURL = self.fileURL {
                    self.diagnostics.append(
                        level: "INFO",
                        sessionID: project.id.uuidString,
                        phase: "project-autosave",
                        event: "project.saved",
                        fields: ["project_path": fileURL.path]
                    )
                }
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
            stabilizationValidations = [:]
            return
        }

        stabilizationStatuses = Dictionary(uniqueKeysWithValues: project.clips.map { clip in
            let status: StabilizationStatus = clip.stabilizationPasses.isEmpty
                ? .none
                : .stale(.validationPending)
            return (clip.id, status)
        })
        stabilizationValidations = [:]
        scheduleTimelineExportReadinessRefresh()
        guard let toolRevision = ffmpegInstallation?.stabilizationCacheToolRevision else { return }

        let resolver = stabilizationStatusResolver
        stabilizationStatusTask = Task { [weak self] in
            var validations: [TimelineClip.ID: StabilizationValidation] = [:]
            for clip in project.clips {
                guard !Task.isCancelled else { return }
                validations[clip.id] = await resolver.validation(
                    for: clip,
                    in: project,
                    toolRevision: toolRevision
                )
            }
            guard !Task.isCancelled,
                  let self,
                  self.project == project,
                  self.ffmpegInstallation?.stabilizationCacheToolRevision == toolRevision else { return }
            self.stabilizationValidations = validations
            self.stabilizationStatuses = validations.mapValues(\.status)
            for (index, clip) in project.clips.enumerated() {
                guard let validation = validations[clip.id] else { continue }
                var fields = [
                    "clip_index": String(index),
                    "clip_id": clip.id.uuidString,
                    "asset_id": clip.assetID.uuidString,
                    "source_range": clip.sourceRange.diagnosticDescription,
                    "status": validation.status.diagnosticName,
                    "artifact_count": String(validation.artifacts.count),
                ]
                if case let .stale(reason) = validation.status {
                    fields["reason"] = reason.localizedDescription
                }
                fields["transform_cache_keys"] = validation.artifacts
                    .map { $0.transforms.key }
                    .joined(separator: ",")
                fields["preview_cache_keys"] = validation.artifacts
                    .map { $0.preview.key }
                    .joined(separator: ",")
                self.diagnostics.append(
                    level: "INFO",
                    sessionID: project.id.uuidString,
                    phase: "stabilization-status",
                    event: "stabilization.status",
                    fields: fields
                )
            }
            self.scheduleTimelineExportReadinessRefresh()
            self.rebuildPlaybackWithValidatedStabilization()
        }
    }

    private func rebuildPlaybackWithValidatedStabilization() {
        guard let project else { return }
        var overrides: [TimelineClip.ID: PlaybackMediaSource] = [:]
        for clip in project.clips {
            guard let validation = stabilizationValidations[clip.id],
                  let source = StabilizedPlaybackSourceBuilder.source(
                    for: clip,
                    validation: validation
                  ) else { continue }
            overrides[clip.id] = source
        }
        playback.rebuild(
            project: project,
            mediaURLs: resolvedMediaURLs,
            clipSourceOverrides: overrides,
            preservingFrame: playheadFrame
        )
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

    private static func changesOnlyVideoFades(
        from previous: ProjectState?,
        to current: ProjectState?
    ) -> Bool {
        guard var previous, var current, previous != current else { return false }
        for index in previous.clips.indices {
            previous.clips[index].videoFadeIn = nil
            previous.clips[index].videoFadeOut = nil
        }
        for index in current.clips.indices {
            current.clips[index].videoFadeIn = nil
            current.clips[index].videoFadeOut = nil
        }
        return previous == current
    }

    private func scheduleTimelineExportReadinessRefresh() {
        timelineExportReadinessTask?.cancel()
        timelineExportReadinessGeneration = UUID()
        let generation = timelineExportReadinessGeneration
        guard let project else {
            timelineExportReadinessError = .invalidTimeline("No project is open.")
            isCheckingTimelineExportReadiness = false
            return
        }
        guard ffmpegInstallation != nil else {
            timelineExportReadinessError = .ffmpegUnavailable
            isCheckingTimelineExportReadiness = false
            return
        }
        let mediaURLs = resolvedMediaURLs
        let statuses = Dictionary(uniqueKeysWithValues: project.clips.map { clip in
            (clip.id, stabilizationStatus(for: clip, in: project))
        })
        timelineExportReadinessError = nil
        isCheckingTimelineExportReadiness = true
        timelineExportReadinessTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    try TimelineExportReadinessValidator().validate(
                        project: project,
                        mediaURLs: mediaURLs,
                        stabilizationStatuses: statuses
                    )
                    return Optional<TimelineExportReadinessError>.none
                } catch let error as TimelineExportReadinessError {
                    return error
                } catch {
                    return TimelineExportReadinessError.invalidTimeline(
                        error.localizedDescription
                    )
                }
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.timelineExportReadinessGeneration == generation else { return }
            self.timelineExportReadinessError = result
            self.isCheckingTimelineExportReadiness = false
        }
    }

    private func report(_ error: Error, phase: String) {
        let message = error.localizedDescription
        errorMessage = message
            + "\n\nIf the problem continues, choose Diagnostics → Copy Diagnostics and share the result."
        diagnostics.append(
            level: "ERROR",
            sessionID: project?.id.uuidString ?? "app",
            phase: phase,
            event: "operation.failed",
            fields: [
                "error_type": String(reflecting: type(of: error)),
                "message": message,
                "project_path": fileURL?.path ?? "<unsaved>",
            ]
        )
    }

    private func logProjectSaved(to url: URL, kind: String) {
        diagnostics.append(
            level: "INFO",
            sessionID: project?.id.uuidString ?? "app",
            phase: "project-save",
            event: "project.saved",
            fields: [
                "kind": kind,
                "project_path": url.path,
            ]
        )
    }

}

private extension UTType {
    static let frogmouthProject = UTType(exportedAs: "dev.frogmouth.project", conformingTo: .json)
}
