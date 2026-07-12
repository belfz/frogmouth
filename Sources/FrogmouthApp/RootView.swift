import AppKit
import FrogmouthCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: EditorViewModel

    var body: some View {
        Group {
            switch model.ffmpegState {
            case .checking:
                ProgressView("Checking FFmpeg installation…")
                    .controlSize(.large)
            case let .unavailable(message):
                FFmpegSetupView(message: message)
            case .ready:
                EditorView(model: model)
            }
        }
        .alert("Replace the current clip?", isPresented: $model.isReplacementConfirmationPresented) {
            Button("Cancel", role: .cancel) { model.cancelReplacement() }
            Button("Replace", role: .destructive) { model.confirmReplacement() }
        } message: {
            Text("The current trim and stabilization choices will be discarded. The source video will not be changed.")
        }
        .alert("frogmouth", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .onDisappear { model.shutdown() }
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
        panel.message = "Choose a Canon EOS R5-style MP4 video"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.requestLoad(url)
    }
}

private struct EmptyEditorView: View {
    let openVideo: () -> Void
    let loadDroppedURL: (URL) -> Void
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Open a wildlife clip")
                .font(.title.bold())
            Text("Canon EOS R5 MP4 is the tested input format.")
                .foregroundStyle(.secondary)
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
