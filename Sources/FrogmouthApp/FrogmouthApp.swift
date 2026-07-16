import FrogmouthCore
import SwiftUI

@main
struct FrogmouthApp: App {
    @StateObject private var model = EditorViewModel()
    @StateObject private var document = ProjectDocumentViewModel()

    var body: some Scene {
        WindowGroup("frogmouth") {
            RootView(model: model, document: document)
                .frame(minWidth: 900, minHeight: 680)
                .task { await model.bootstrap() }
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
            CommandMenu("Clip") {
                Button("Split at Playhead", action: document.splitSelectedClip)
                    .disabled(!document.canSplitSelectedClip)
                Button("Duplicate", action: document.duplicateSelectedClip)
                    .disabled(!document.canEditSelectedClip)
                Button("Delete", role: .destructive, action: document.deleteSelectedClip)
                    .disabled(!document.canEditSelectedClip)
            }
            CommandMenu("Diagnostics") {
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Button("Reveal Logs in Finder") { model.revealLogs() }
            }
        }
    }
}
