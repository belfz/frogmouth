import FrogmouthCore
import SwiftUI

@main
struct FrogmouthApp: App {
    @StateObject private var application: ApplicationViewModel
    @StateObject private var document: ProjectDocumentViewModel

    init() {
        let diagnostics = DiagnosticLogStore()
        _application = StateObject(wrappedValue: ApplicationViewModel(diagnostics: diagnostics))
        _document = StateObject(wrappedValue: ProjectDocumentViewModel(
            diagnostics: diagnostics
        ))
    }

    var body: some Scene {
        WindowGroup("frogmouth") {
            RootView(application: application, document: document)
                .frame(minWidth: 900, minHeight: 680)
                .task { await application.bootstrap() }
                .onOpenURL(perform: document.openExternalURL)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project", action: document.requestNewProject)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(document.isBusy)
                Button("Open Project…", action: document.presentOpenProjectPanel)
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(document.isBusy)
                Divider()
                Button("Import Videos…", action: document.presentImportVideosPanel)
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(document.isBusy)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save", action: document.save)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!document.canSave)
                Button("Save As…", action: document.saveAs)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!document.canSave)
                Divider()
                Button("Close Project", action: document.requestCloseProject)
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(!document.hasProject || document.isBusy)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: document.undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!document.canUndo || document.isBusy)
                Button("Redo", action: document.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!document.canRedo || document.isBusy)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: application.checkForUpdates)
            }
            CommandMenu("Clip") {
                Button("Split at Playhead (C)", action: document.splitSelectedClip)
                    .disabled(!document.canSplitSelectedClip)
                Button("Duplicate", action: document.duplicateSelectedClip)
                    .disabled(!document.canEditSelectedClip)
                Button("Delete (Backspace)", role: .destructive, action: document.deleteSelectedClip)
                    .disabled(!document.canEditSelectedClip)
            }
            CommandMenu("Diagnostics") {
                Button("Copy Diagnostics") { application.copyDiagnostics() }
                Button("Reveal Logs in Finder") { application.revealLogs() }
            }
        }
    }
}
