@preconcurrency import AVFoundation
import AppKit
import FrogmouthCore
import SwiftUI

@MainActor
final class EditorViewModel: ObservableObject {
    enum FFmpegState: Equatable {
        case checking
        case unavailable(String)
        case ready(FFmpegInstallation)
    }

    @Published private(set) var ffmpegState: FFmpegState = .checking
    @Published private(set) var media: MediaInfo?
    @Published var editState = EditState(sourceDuration: 1)
    @Published private(set) var player = AVPlayer()
    @Published private(set) var processingPhase: ProcessingPhase = .idle
    @Published var errorMessage: String?
    @Published var isReplacementConfirmationPresented = false
    @Published var lastExportURL: URL?

    private let locator: any FFmpegLocating
    private let mediaInspector: any MediaInspecting
    private let diagnostics: DiagnosticLogStore
    private let runner: FFmpegRunner
    private var workspace: SessionWorkspace?
    private var history = EditHistory()
    private var pendingReplacementURL: URL?
    private var processingTask: Task<Void, Never>?
    private var currentPreviewURL: URL?
    private var isShowingProcessedPreview = false
    private var hasBootstrapped = false

    init(
        locator: any FFmpegLocating = FFmpegLocator(),
        mediaInspector: any MediaInspecting = MediaInspector(),
        diagnostics: DiagnosticLogStore = DiagnosticLogStore()
    ) {
        self.locator = locator
        self.mediaInspector = mediaInspector
        self.diagnostics = diagnostics
        runner = FFmpegRunner(diagnostics: diagnostics)
    }

    var isProcessing: Bool { processingPhase != .idle }
    var canUndo: Bool { history.canUndo && !isProcessing }
    var canRedo: Bool { history.canRedo && !isProcessing }
    var canConfirmTrim: Bool { editState.hasPendingTrim && !isProcessing }
    var canApplyStabilization: Bool {
        media != nil && !editState.hasPendingTrim && !isProcessing && ffmpegInstallation != nil
    }
    var canExport: Bool { canApplyStabilization }
    var diagnosticsDirectory: URL { diagnostics.directory }

    private var ffmpegInstallation: FFmpegInstallation? {
        if case let .ready(installation) = ffmpegState { installation } else { nil }
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        diagnostics.append(level: "INFO", sessionID: "app", phase: "startup", message: "validating FFmpeg")
        do {
            let installation = try await locator.locateAndValidate()
            ffmpegState = .ready(installation)
            diagnostics.append(
                level: "INFO",
                sessionID: "app",
                phase: "startup",
                message: "ffmpeg=\(installation.executableURL.path) version=\(installation.versionDescription)"
            )
        } catch {
            ffmpegState = .unavailable(error.localizedDescription)
            diagnostics.append(level: "ERROR", sessionID: "app", phase: "startup", message: error.localizedDescription)
        }
    }

    func requestLoad(_ url: URL) {
        guard media != nil else {
            Task { await load(url) }
            return
        }
        pendingReplacementURL = url
        isReplacementConfirmationPresented = true
    }

    func confirmReplacement() {
        guard let pendingReplacementURL else { return }
        self.pendingReplacementURL = nil
        isReplacementConfirmationPresented = false
        Task { await load(pendingReplacementURL) }
    }

    func cancelReplacement() {
        pendingReplacementURL = nil
        isReplacementConfirmationPresented = false
    }

    func setDraftTrim(_ trim: TrimRange) {
        editState.pendingTrim = trim.normalized(for: editState.duration)
        constrainPlayerToPendingTrim()
    }

    func finishTrimDrag(from _: TrimRange) {
        // Draft handle motion is intentionally not an edit operation. Confirm Trim
        // records the whole range as one undoable action.
    }

    func confirmTrim() {
        guard canConfirmTrim else { return }
        let previous = editState
        let committed = editState.committingPendingTrim()
        history.record(previous: previous, current: committed)
        editState = committed
        lastExportURL = nil

        if committed.hasStabilization {
            renderExistingPipelinePreview()
        } else {
            showOriginalPreview()
        }
    }

    func applyStabilization(_ mode: StabilizationMode) {
        guard mode != .none,
              canApplyStabilization,
              processingTask == nil,
              let installation = ffmpegInstallation,
              let media,
              let workspace,
              let profile = StabilizationProfile.profile(for: mode) else { return }

        let previous = editState
        let passID = UUID()
        let transformsURL = workspace.transformsURL(for: passID)
        let pass = StabilizationPass(id: passID, mode: mode, transformsURL: transformsURL)
        let prospective = previous.appending(pass)
        let previewURL = workspace.previewURL()
        let sessionID = workspace.directory.lastPathComponent

        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { processingTask = nil }
            do {
                processingPhase = .analyzing(progress: 0)
                let analysisArguments = FFmpegCommandFactory.analysis(
                    input: media.url,
                    sourceDuration: media.duration,
                    operations: previous.operations,
                    transforms: transformsURL,
                    profile: profile
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: analysisArguments,
                    duration: previous.duration,
                    sessionID: sessionID,
                    phase: "analysis-\(passID.uuidString)"
                ) { [weak self] progress in
                    Task { @MainActor in self?.processingPhase = .analyzing(progress: progress) }
                }

                try Task.checkCancellation()
                processingPhase = .renderingPreview(progress: 0)
                let previewArguments = FFmpegCommandFactory.preview(
                    input: media.url,
                    sourceDuration: media.duration,
                    operations: prospective.operations,
                    output: previewURL
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: previewArguments,
                    duration: prospective.duration,
                    sessionID: sessionID,
                    phase: "preview-\(passID.uuidString)"
                ) { [weak self] progress in
                    Task { @MainActor in self?.processingPhase = .renderingPreview(progress: progress) }
                }

                guard previous == editState else { throw FrogmouthError.cancelled }
                history.record(previous: previous, current: prospective)
                editState = prospective
                installProcessedPreview(previewURL)
                processingPhase = .idle
                lastExportURL = nil
            } catch is CancellationError {
                processingPhase = .idle
                try? FileManager.default.removeItem(at: transformsURL)
                try? FileManager.default.removeItem(at: previewURL)
            } catch let error as FrogmouthError where error == .cancelled {
                processingPhase = .idle
                try? FileManager.default.removeItem(at: transformsURL)
                try? FileManager.default.removeItem(at: previewURL)
            } catch {
                processingPhase = .idle
                errorMessage = error.localizedDescription
                try? FileManager.default.removeItem(at: transformsURL)
                try? FileManager.default.removeItem(at: previewURL)
            }
        }
    }

    func undo() {
        guard let state = history.undo(current: editState) else { return }
        restoreEditState(state)
    }

    func redo() {
        guard let state = history.redo(current: editState) else { return }
        restoreEditState(state)
    }

    func togglePlayback() {
        guard media != nil else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            let current = timelineTime
            if current >= editState.pendingTrim.end || current < editState.pendingTrim.start {
                seek(to: editState.pendingTrim.start)
            }
            player.play()
        }
    }

    func seek(to seconds: TimeInterval) {
        let playerSeconds: TimeInterval
        if isShowingProcessedPreview {
            playerSeconds = seconds
        } else {
            let plan = FFmpegCommandFactory.pipeline(
                sourceDuration: editState.sourceDuration,
                operations: editState.operations
            )
            playerSeconds = plan.inputStart + seconds
        }
        player.seek(
            to: CMTime(seconds: max(0, playerSeconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    var timelineTime: TimeInterval {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return editState.pendingTrim.start }
        if isShowingProcessedPreview { return seconds }
        let plan = FFmpegCommandFactory.pipeline(
            sourceDuration: editState.sourceDuration,
            operations: editState.operations
        )
        return max(0, seconds - plan.inputStart)
    }

    func enforcePlaybackBounds() {
        guard player.timeControlStatus == .playing,
              timelineTime >= editState.pendingTrim.end else { return }
        player.pause()
        seek(to: editState.pendingTrim.end)
    }

    func export(to destination: URL) {
        guard canExport,
              processingTask == nil,
              let installation = ffmpegInstallation,
              let media,
              let workspace else { return }

        let snapshot = editState
        let sessionID = workspace.directory.lastPathComponent
        let temporaryOutput = destination.deletingLastPathComponent()
            .appendingPathComponent(".frogmouth-\(UUID().uuidString).partial.mp4")

        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: temporaryOutput)
                processingTask = nil
            }
            do {
                processingPhase = .exporting(progress: 0)
                let arguments = FFmpegCommandFactory.export(
                    input: media.url,
                    sourceDuration: media.duration,
                    operations: snapshot.operations,
                    output: temporaryOutput,
                    targetVideoBitrate: QualityPolicy.targetVideoBitrate(sourceBitrate: media.videoBitrate)
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: arguments,
                    duration: snapshot.duration,
                    sessionID: sessionID,
                    phase: "export"
                ) { [weak self] progress in
                    Task { @MainActor in self?.processingPhase = .exporting(progress: progress) }
                }

                let outputInfo = try await mediaInspector.inspect(url: temporaryOutput)
                try validate(outputInfo: outputInfo, against: media, duration: snapshot.duration)
                try AtomicTimelineExportFileFinalizer().finalize(
                    temporaryURL: temporaryOutput,
                    destinationURL: destination
                )
                lastExportURL = destination
                processingPhase = .idle
                diagnostics.append(level: "INFO", sessionID: sessionID, phase: "export", message: "completed output=\(destination.path)")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                processingPhase = .idle
            } catch let error as FrogmouthError where error == .cancelled {
                processingPhase = .idle
            } catch {
                processingPhase = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        runner.cancel()
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.contents(), forType: .string)
    }

    func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([diagnostics.directory])
    }

    func shutdown() {
        cancelProcessing()
        cleanupCurrentSession()
    }

    private func load(_ url: URL) async {
        do {
            let inspected = try await mediaInspector.inspect(url: url)
            let newWorkspace = try SessionWorkspace()
            cleanupCurrentSession()
            workspace = newWorkspace
            media = inspected
            editState = EditState(sourceDuration: inspected.duration)
            history.clear()
            isShowingProcessedPreview = false
            player = AVPlayer(url: url)
            lastExportURL = nil
            diagnostics.append(
                level: "INFO",
                sessionID: newWorkspace.directory.lastPathComponent,
                phase: "import",
                message: "source=\(url.path) size=\(inspected.width)x\(inspected.height) fps=\(inspected.frameRate) bitrate=\(inspected.videoBitrate) codec=\(inspected.videoCodec)"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreEditState(_ state: EditState) {
        editState = state
        lastExportURL = nil
        if state.hasStabilization {
            renderExistingPipelinePreview()
        } else {
            showOriginalPreview()
        }
    }

    private func renderExistingPipelinePreview() {
        guard processingTask == nil,
              let installation = ffmpegInstallation,
              let media,
              let workspace else { return }

        let snapshot = editState
        let previewURL = workspace.previewURL()
        let sessionID = workspace.directory.lastPathComponent
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { processingTask = nil }
            do {
                processingPhase = .renderingPreview(progress: 0)
                let arguments = FFmpegCommandFactory.preview(
                    input: media.url,
                    sourceDuration: media.duration,
                    operations: snapshot.operations,
                    output: previewURL
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: arguments,
                    duration: snapshot.duration,
                    sessionID: sessionID,
                    phase: "preview-existing"
                ) { [weak self] progress in
                    Task { @MainActor in self?.processingPhase = .renderingPreview(progress: progress) }
                }
                guard snapshot == editState else { throw FrogmouthError.cancelled }
                installProcessedPreview(previewURL)
                processingPhase = .idle
            } catch is CancellationError {
                processingPhase = .idle
                try? FileManager.default.removeItem(at: previewURL)
            } catch let error as FrogmouthError where error == .cancelled {
                processingPhase = .idle
                try? FileManager.default.removeItem(at: previewURL)
            } catch {
                processingPhase = .idle
                errorMessage = error.localizedDescription
                try? FileManager.default.removeItem(at: previewURL)
            }
        }
    }

    private func installProcessedPreview(_ url: URL) {
        player.pause()
        let previousURL = currentPreviewURL
        currentPreviewURL = url
        isShowingProcessedPreview = true
        player = AVPlayer(url: url)
        if let previousURL, previousURL != url {
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    private func showOriginalPreview() {
        guard let media else { return }
        player.pause()
        isShowingProcessedPreview = false
        player = AVPlayer(url: media.url)
        seek(to: editState.pendingTrim.start)
        if let currentPreviewURL {
            try? FileManager.default.removeItem(at: currentPreviewURL)
            self.currentPreviewURL = nil
        }
    }

    private func constrainPlayerToPendingTrim() {
        let time = timelineTime
        if time < editState.pendingTrim.start || time > editState.pendingTrim.end {
            seek(to: editState.pendingTrim.start)
        }
    }

    private func validate(outputInfo: MediaInfo, against source: MediaInfo, duration: TimeInterval) throws {
        guard outputInfo.videoCodec.lowercased().contains("hvc") || outputInfo.videoCodec.lowercased().contains("hev") else {
            throw FrogmouthError.outputValidationFailed("The output is not HEVC.")
        }
        guard outputInfo.width == source.width, outputInfo.height == source.height else {
            throw FrogmouthError.outputValidationFailed("The output dimensions changed unexpectedly.")
        }
        let frameTolerance = 1 / max(1, source.frameRate)
        guard abs(outputInfo.duration - duration) <= max(frameTolerance, 0.1) else {
            throw FrogmouthError.outputValidationFailed("The output duration does not match the committed edit pipeline.")
        }
    }

    private func cleanupCurrentSession() {
        player.pause()
        workspace?.removeAll()
        workspace = nil
        currentPreviewURL = nil
        isShowingProcessedPreview = false
    }
}
