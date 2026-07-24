import AppKit
import Combine
import FrogmouthCore

@MainActor
final class ApplicationViewModel: ObservableObject {
    private static let releasesURL = URL(
        string: "https://github.com/belfz/frogmouth/releases/latest"
    )!

    enum FFmpegState: Equatable {
        case checking
        case unavailable(String)
        case ready(FFmpegInstallation)
    }

    @Published private(set) var ffmpegState: FFmpegState = .checking

    private let locator: any FFmpegLocating
    private let diagnostics: DiagnosticLogStore
    private var hasBootstrapped = false

    init(
        locator: any FFmpegLocating = FFmpegLocator(),
        diagnostics: DiagnosticLogStore = DiagnosticLogStore()
    ) {
        self.locator = locator
        self.diagnostics = diagnostics
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        diagnostics.append(
            level: "INFO",
            sessionID: "app",
            phase: "startup",
            message: "validating FFmpeg"
        )
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
            diagnostics.append(
                level: "ERROR",
                sessionID: "app",
                phase: "startup",
                message: error.localizedDescription
            )
        }
    }

    func copyDiagnostics() {
        Task {
            let contents = await diagnostics.contentsAsync()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contents, forType: .string)
        }
    }

    func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([diagnostics.directory])
    }

    func checkForUpdates() {
        NSWorkspace.shared.open(Self.releasesURL)
    }
}
