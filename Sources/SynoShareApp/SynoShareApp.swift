import AppKit
import SwiftUI
import SynoShareAppCore

@main
struct SynoShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SynoShare", id: "main") {
            ContentView(model: appDelegate.model)
                .frame(minWidth: 620, idealWidth: 720, minHeight: 640, idealHeight: 820)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Owns the model so quitting can stop the engine cleanly (finish chunks, flush state).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DownloadViewModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isRunning, !confirmQuitWhileDownloading() { return .terminateCancel }
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
