import AppKit
import FrogmouthCore
import SwiftUI

struct RootView: View {
    @ObservedObject var application: ApplicationViewModel
    @ObservedObject var document: ProjectDocumentViewModel

    var body: some View {
        Group {
            switch application.ffmpegState {
            case .checking:
                ProgressView("Checking FFmpeg installation…")
                    .controlSize(.large)
                    .accessibilityLabel("Checking FFmpeg installation")
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

            if document.timelineExportProcessingPhase != .idle {
                Color.black.opacity(0.22).ignoresSafeArea()
                VStack(spacing: 14) {
                    if let progress = document.timelineExportProcessingPhase.progress {
                        ProgressView(
                            document.timelineExportProcessingPhase.title,
                            value: progress,
                            total: 1
                        )
                        .frame(width: 280)
                    } else {
                        ProgressView(document.timelineExportProcessingPhase.title)
                            .controlSize(.large)
                    }
                    Button("Cancel", role: .cancel) {
                        document.cancelTimelineExport()
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 18)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Timeline export in progress")
                .accessibilityIdentifier("timeline-export-progress")
                .accessibilityValue(accessibilityProgress(document.timelineExportProcessingPhase))
            } else if document.stabilizationProcessingPhase != .idle {
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
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Stabilization in progress")
                .accessibilityIdentifier("stabilization-progress")
                .accessibilityValue(accessibilityProgress(document.stabilizationProcessingPhase))
            } else if document.isBusy {
                Color.black.opacity(0.15).ignoresSafeArea()
                ProgressView(activityTitle)
                    .controlSize(.large)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 18)
                    .accessibilityLabel(activityTitle)
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

    private func accessibilityProgress(_ phase: ProcessingPhase) -> String {
        guard let progress = phase.progress else { return phase.title }
        return "\(phase.title) \(Int((progress * 100).rounded())) percent"
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
