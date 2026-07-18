import AppKit
import FrogmouthCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: EditorViewModel
    @ObservedObject var document: ProjectDocumentViewModel

    var body: some View {
        Group {
            switch model.ffmpegState {
            case .checking:
                ProgressView("Checking FFmpeg installation…")
                    .controlSize(.large)
            case let .unavailable(message):
                FFmpegSetupView(message: message)
            case let .ready(installation):
                ProjectRootView(document: document)
                    .task(id: installation.stabilizationCacheToolRevision) {
                        document.configureFFmpegInstallation(installation)
                    }
            }
        }
        .navigationTitle(document.displayName)
        .background(WindowCloseGuard(document: document).frame(width: 0, height: 0))
        .alert("Save changes before continuing?", isPresented: $document.isUnsavedConfirmationPresented) {
            Button("Cancel", role: .cancel, action: document.cancelPendingTransition)
            Button("Discard Changes", role: .destructive, action: document.resolveUnsavedChangesByDiscarding)
            Button("Save", action: document.resolveUnsavedChangesBySaving)
        } message: {
            Text("The current project has changes that have not been saved. Its source videos will not be changed.")
        }
        .alert("frogmouth", isPresented: Binding(
            get: { document.errorMessage != nil },
            set: { if !$0 { document.errorMessage = nil } }
        )) {
            Button("OK") { document.errorMessage = nil }
        } message: {
            Text(document.errorMessage ?? "Unknown error")
        }
        .onDisappear {
            document.shutdown()
            model.shutdown()
        }
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let document: ProjectDocumentViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.install(on: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.document = document
        DispatchQueue.main.async {
            context.coordinator.install(on: view.window)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall(from: view.window)
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var document: ProjectDocumentViewModel
        private weak var installedWindow: NSWindow?
        private weak var originalDelegate: (any NSWindowDelegate)?
        private var allowsNextClose = false

        init(document: ProjectDocumentViewModel) {
            self.document = document
        }

        func install(on window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            uninstall(from: installedWindow)
            originalDelegate = window.delegate
            installedWindow = window
            window.delegate = self
        }

        func uninstall(from window: NSWindow?) {
            guard let window, window.delegate === self else { return }
            window.delegate = originalDelegate
            installedWindow = nil
            originalDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowsNextClose {
                allowsNextClose = false
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            guard document.hasUnsavedChanges else {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            document.requestWindowClose { [weak self, weak sender] in
                guard let self, let sender else { return }
                allowsNextClose = true
                sender.performClose(nil)
            }
            return false
        }
    }
}

private struct ProjectRootView: View {
    @ObservedObject var document: ProjectDocumentViewModel
    @State private var isDropTarget = false

    var body: some View {
        ZStack {
            if let project = document.project {
                ProjectEditorShell(document: document, project: project)
            } else {
                ProjectStartupView(document: document)
            }

            if document.stabilizationProcessingPhase != .idle {
                Color.black.opacity(0.22).ignoresSafeArea()
                VStack(spacing: 14) {
                    if let progress = document.stabilizationProcessingPhase.progress {
                        ProgressView(
                            document.stabilizationProcessingPhase.title,
                            value: progress,
                            total: 1
                        )
                        .frame(width: 280)
                    } else {
                        ProgressView(document.stabilizationProcessingPhase.title)
                            .controlSize(.large)
                    }
                    Button("Cancel", role: .cancel) {
                        document.cancelStabilizationProcessing()
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 18)
            } else if document.isBusy {
                Color.black.opacity(0.15).ignoresSafeArea()
                ProgressView(activityTitle)
                    .controlSize(.large)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 18)
            }
        }
        .background(isDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            document.handleDrop(urls)
        } isTargeted: {
            isDropTarget = $0
        }
    }

    private var activityTitle: String {
        guard let progress = document.importProgress else { return "Working…" }
        return "Importing \(progress.completed + 1) of \(progress.total): \(progress.filename)"
    }
}

private struct ProjectStartupView: View {
    @ObservedObject var document: ProjectDocumentViewModel

    var body: some View {
        VStack(spacing: 20) {
            FrogmouthMarkView()
            Text("Start a frogmouth project")
                .font(.largeTitle.bold())
            Text("Projects keep your edit decisions in a lightweight .frogmouth file. Source videos remain untouched.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button("New Project", action: document.requestNewProject)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Open Project…", action: document.presentOpenProjectPanel)
                    .controlSize(.large)
                Button("Create from Videos…", action: document.presentImportVideosPanel)
                    .controlSize(.large)
            }
            Text("You can also drop one .frogmouth project or several videos here.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct FrogmouthMarkView: View {
    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "FrogmouthMark", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "bird")
                    .resizable()
                    .scaledToFit()
            }
        }
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .frame(width: 180, height: 150)
        .accessibilityLabel("frogmouth")
    }
}

private struct FFmpegSetupView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("FFmpeg setup required")
                .font(.largeTitle.bold())
            Text(message)
                .foregroundStyle(.secondary)
            Text("Install a tested FFmpeg build with libvidstab:")
            VStack(alignment: .leading, spacing: 8) {
                Text("brew tap homebrew-ffmpeg/ffmpeg")
                Text("brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-libvidstab")
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("Restart frogmouth after installation. FFmpeg is verified automatically when the app starts.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(40)
    }
}

private struct EditorView: View {
    @ObservedObject var model: EditorViewModel

    var body: some View {
        ZStack {
            if let media = model.media {
                LoadedEditorView(model: model, media: media)
            } else {
                EmptyEditorView(openVideo: openVideo, loadDroppedURL: model.requestLoad)
            }

            if model.isProcessing {
                Color.black.opacity(0.22).ignoresSafeArea()
                ProcessingCard(model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: openVideo) {
                    Label("Open Video", systemImage: "folder")
                }
                .disabled(model.isProcessing)

                Button(action: model.undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)

                Button(action: model.redo) {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
            }
        }
    }

    private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video clip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.requestLoad(url)
    }
}

private struct EmptyEditorView: View {
    let openVideo: () -> Void
    let loadDroppedURL: (URL) -> Void
    @State private var isDropTarget = false

    private static let frogmouthMark: NSImage? = {
        guard let url = Bundle.module.url(forResource: "FrogmouthMark", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        VStack(spacing: 18) {
            if let frogmouthMark = Self.frogmouthMark {
                Image(nsImage: frogmouthMark)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 224, height: 192)
                    .accessibilityLabel("frogmouth")
            } else {
                Image(systemName: "bird")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
                    .accessibilityLabel("frogmouth")
            }
            Text("Open a video clip")
                .font(.title.bold())
            Button("Open Video…", action: openVideo)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("or drop a video here")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTarget ? Color.accentColor.opacity(0.10) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            loadDroppedURL(url)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}

private struct LoadedEditorView: View {
    @ObservedObject var model: EditorViewModel
    let media: MediaInfo

    var body: some View {
        VStack(spacing: 0) {
            NativeVideoPlayer(player: model.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .onTapGesture { model.togglePlayback() }

            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                        Text(mediaSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let lastExportURL = model.lastExportURL {
                        Button("Reveal Export") {
                            NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
                        }
                    }
                }

                TimelineView(.periodic(from: .now, by: 0.10)) { _ in
                    TrimScrubber(
                        duration: model.editState.duration,
                        trim: model.editState.pendingTrim,
                        playhead: model.timelineTime,
                        onDraftTrim: model.setDraftTrim,
                        onCommitTrim: model.finishTrimDrag,
                        onSeek: model.seek
                    )
                    .onChange(of: model.timelineTime) { _, _ in model.enforcePlaybackBounds() }
                }

                HStack {
                    Text(model.editState.hasPendingTrim
                         ? "Confirm this range before stabilization or export."
                         : "Adjust either handle to prepare another trim.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Confirm Trim", action: model.confirmTrim)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canConfirmTrim)
                }

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Stabilization")
                            .font(.headline)
                        HStack {
                            Button("Apply Steady") { model.applyStabilization(.steady) }
                                .buttonStyle(.bordered)
                            Button("Apply Natural Motion") { model.applyStabilization(.naturalMotion) }
                                .buttonStyle(.bordered)
                        }
                        .disabled(!model.canApplyStabilization)
                        Text("Each completed pass is added on top of the existing edits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider().frame(height: 62)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("High-quality HEVC")
                            .font(.headline)
                        Text("Original \(media.width)×\(media.height) at \(formatFPS(media.frameRate)) fps · automatic quality · smaller file")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Export…", action: export)
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canExport)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
            .background(.regularMaterial)
        }
    }

    private var mediaSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: media.fileSize, countStyle: .file)
        return "\(media.width)×\(media.height) · \(formatFPS(media.frameRate)) fps · \(media.videoCodec.uppercased()) · \(size)"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = media.url.deletingLastPathComponent()
        panel.nameFieldStringValue = media.url.deletingPathExtension().lastPathComponent + "—frogmouth.mp4"
        panel.message = "Export a high-quality HEVC video"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.export(to: destination)
    }

    private func formatFPS(_ fps: Double) -> String {
        fps.rounded() == fps ? String(Int(fps)) : String(format: "%.2f", fps)
    }
}

private struct ProcessingCard: View {
    @ObservedObject var model: EditorViewModel

    var body: some View {
        VStack(spacing: 18) {
            Text(model.processingPhase.title)
                .font(.headline)
            if let progress = model.processingPhase.progress {
                ProgressView(value: progress)
                    .frame(width: 320)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
            }
            Button("Cancel", role: .cancel, action: model.cancelProcessing)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 24)
    }
}
