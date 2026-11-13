import AppKit
import SwiftUI
import SynoShareAppCore

@main
struct SynoShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SynoShare", id: "main") {
            ContentView(model: appDelegate.model, files: appDelegate.files)
                .frame(minWidth: 620, idealWidth: 720, minHeight: 640, idealHeight: 820)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(before: .windowList) { OpenFilesWindowButton() }
        }

        Window("Files", id: FilesWindow.id) {
            FilesView(model: appDelegate.files)
                .frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 640)
        }
    }
}

enum FilesWindow {
    static let id = "files"
}

/// Opens the Files window (menu command and main window button).
struct OpenFilesWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Files…", systemImage: "list.bullet.rectangle.portrait") { openWindow(id: FilesWindow.id) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Show every file with its status, and repair the files you choose.")
    }
}

/// Owns the model so quitting can stop the engine cleanly (finish chunks, flush state).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: DownloadViewModel
    let files: FilesViewModel

    override init() {
        let model = DownloadViewModel()
        self.model = model
        files = FilesViewModel(download: model)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.needsQuitConfirmation, !confirmQuitWhileDownloading() { return .terminateCancel }
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuitWhileDownloading() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop downloading and quit?"
        alert.informativeText = "Progress is saved. Partly downloaded files resume where they stopped "
            + "the next time you click Download All."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
