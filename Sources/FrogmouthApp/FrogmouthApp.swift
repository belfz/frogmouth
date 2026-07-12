import FrogmouthCore
import SwiftUI

@main
struct FrogmouthApp: App {
    @StateObject private var model = EditorViewModel()

    var body: some Scene {
        WindowGroup("frogmouth") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 680)
                .task { await model.bootstrap() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandMenu("Diagnostics") {
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Button("Reveal Logs in Finder") { model.revealLogs() }
            }
        }
    }
}

