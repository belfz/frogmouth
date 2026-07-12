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
    @Published var editState = EditState(trim: TrimRange(start: 0, end: 1))
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
    var canExport: Bool { media != nil && !isProcessing && ffmpegInstallation != nil }
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
        guard let media else { return }
        editState.trim = trim.normalized(for: media.duration)
        constrainPlayerToTrim()
    }

    func commitTrim(from previousTrim: TrimRange) {
        guard previousTrim != editState.trim else { return }
        let previous = EditState(trim: previousTrim, stabilization: editState.stabilization)
        history.record(previous: previous, current: editState)
        objectWillChange.send()
        invalidateRenderedPreview()
        if editState.stabilization != .none {
            renderStabilizedPreview()
        }
    }

    func setStabilization(_ mode: StabilizationMode) {
        guard editState.stabilization != mode else { return }
        let previous = editState
        editState.stabilization = mode
        history.record(previous: previous, current: editState)
        objectWillChange.send()
        invalidateRenderedPreview()
        if mode == .none {
            showOriginalPreview()
        } else {
            renderStabilizedPreview()
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
            if current >= editState.trim.end || current < editState.trim.start {
                seek(to: editState.trim.start)
            }
            player.play()
        }
    }

    func seek(to seconds: TimeInterval) {
        let playerSeconds = editState.stabilization == .none ? seconds : seconds - editState.trim.start
        player.seek(
            to: CMTime(seconds: max(0, playerSeconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    var timelineTime: TimeInterval {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return editState.trim.start }
        return editState.stabilization == .none ? seconds : editState.trim.start + seconds
    }

    func enforcePlaybackBounds() {
        guard player.timeControlStatus == .playing, timelineTime >= editState.trim.end else { return }
        player.pause()
        seek(to: editState.trim.end)
    }

    func renderStabilizedPreview() {
        guard processingTask == nil,
              let installation = ffmpegInstallation,
              let media,
              let workspace,
              let profile = StabilizationProfile.profile(for: editState.stabilization) else { return }

        let sessionID = workspace.directory.lastPathComponent
        let snapshot = editState
        workspace.removeGeneratedMedia()

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                processingPhase = .analyzing(progress: 0)
                let analysisArguments = FFmpegCommandFactory.analysis(
                    input: media.url,
                    trim: snapshot.trim,
                    transforms: workspace.transformsURL,
                    profile: profile
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: analysisArguments,
                    duration: snapshot.trim.duration,
                    sessionID: sessionID,
                    phase: "analysis"
                ) { [weak self] progress in
                    Task { @MainActor in self?.processingPhase = .analyzing(progress: progress) }
                }

                try Task.checkCancellation()
                processingPhase = .renderingPreview(progress: 0)
                let previewArguments = FFmpegCommandFactory.preview(
                    input: media.url,
                    trim: snapshot.trim,
                    transforms: workspace.transformsURL,
                    output: workspace.previewURL,
                    profile: profile
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: previewArguments,
                    duration: snapshot.trim.duration,
                    sessionID: sessionID,
                    phase: "preview"
                ) { [weak self] progress in
                    Task { @MainActor in self?.processingPhase = .renderingPreview(progress: progress) }
                }

                guard snapshot == editState else { throw FrogmouthError.cancelled }
                player.pause()
                player = AVPlayer(url: workspace.previewURL)
                processingPhase = .idle
            } catch is CancellationError {
                processingPhase = .idle
                showOriginalPreview()
            } catch let error as FrogmouthError where error == .cancelled {
                processingPhase = .idle
                showOriginalPreview()
            } catch {
                processingPhase = .idle
                errorMessage = error.localizedDescription
                showOriginalPreview()
            }
            processingTask = nil
        }
    }

    func export(to destination: URL) {
        guard processingTask == nil,
              let installation = ffmpegInstallation,
              let media,
              let workspace else { return }

        let profile = StabilizationProfile.profile(for: editState.stabilization)
        if profile != nil && !FileManager.default.fileExists(atPath: workspace.transformsURL.path) {
            errorMessage = "The stabilized preview must finish before export."
            return
        }

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
                    trim: snapshot.trim,
                    transforms: profile == nil ? nil : workspace.transformsURL,
                    output: temporaryOutput,
                    profile: profile,
                    targetVideoBitrate: QualityPolicy.targetVideoBitrate(sourceBitrate: media.videoBitrate)
                )
                _ = try await runner.run(
                    executable: installation.executableURL,
                    arguments: arguments,
                    duration: snapshot.trim.duration,
                    sessionID: sessionID,
                    phase: "export"
                ) { [weak self] progress in
                    Task { @MainActor in self?.processingPhase = .exporting(progress: progress) }
                }

                let outputInfo = try await mediaInspector.inspect(url: temporaryOutput)
                try validate(outputInfo: outputInfo, against: media, trim: snapshot.trim)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryOutput)
                } else {
                    try FileManager.default.moveItem(at: temporaryOutput, to: destination)
                }
                lastExportURL = destination
                processingPhase = .idle
                diagnostics.append(level: "INFO", sessionID: sessionID, phase: "export", message: "completed output=\(destination.path)")
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
            editState = EditState(trim: TrimRange(start: 0, end: inspected.duration), stabilization: .none)
            history.clear()
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
        objectWillChange.send()
        invalidateRenderedPreview()
        if state.stabilization == .none {
            showOriginalPreview()
        } else {
            renderStabilizedPreview()
        }
    }

    private func invalidateRenderedPreview() {
        workspace?.removeGeneratedMedia()
    }

    private func showOriginalPreview() {
        guard let media else { return }
        player.pause()
        player = AVPlayer(url: media.url)
        seek(to: editState.trim.start)
    }

    private func constrainPlayerToTrim() {
        guard editState.stabilization == .none else { return }
        let time = player.currentTime().seconds
        if time < editState.trim.start || time > editState.trim.end {
            seek(to: editState.trim.start)
        }
    }

    private func validate(outputInfo: MediaInfo, against source: MediaInfo, trim: TrimRange) throws {
        guard outputInfo.videoCodec.lowercased().contains("hvc") || outputInfo.videoCodec.lowercased().contains("hev") else {
            throw FrogmouthError.outputValidationFailed("The output is not HEVC.")
        }
        guard outputInfo.width == source.width, outputInfo.height == source.height else {
            throw FrogmouthError.outputValidationFailed("The output dimensions changed unexpectedly.")
        }
        let frameTolerance = 1 / max(1, source.frameRate)
        guard abs(outputInfo.duration - trim.duration) <= max(frameTolerance, 0.1) else {
            throw FrogmouthError.outputValidationFailed("The output duration does not match the trim range.")
        }
    }

    private func cleanupCurrentSession() {
        player.pause()
        workspace?.removeAll()
        workspace = nil
    }
}
