import AppKit
import SwiftUI
import SynoShareAppCore

/// Share link, password, destination and the two options.
struct ConnectionSection: View {
    @Bindable var model: DownloadViewModel

    var body: some View {
        Section("Share") {
            TextField("Share link", text: $model.shareURL, prompt: Text("https://gofile.me/…"))
                .textContentType(.URL)
                .disabled(model.isBusy)
                .accessibilityLabel("Share link")
            if let advice = model.error(for: .shareURL) { FieldErrorView(advice: advice) }

            SecureField("Password", text: $model.password)
                .disabled(model.isBusy)
                .accessibilityLabel("Share password")
            if let advice = model.error(for: .password) { FieldErrorView(advice: advice) }

            Toggle("Remember password in Keychain", isOn: $model.rememberPassword)
                .help("Stores the password only in your login Keychain, never in files or settings.")
        }

        Section("Destination") {
            LabeledContent("Folder") {
                HStack {
                    Text(model.destination?.path ?? "None chosen")
                        .foregroundStyle(model.destination == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.destination?.path ?? "")
                    Button("Choose…", action: chooseDestination)
                        .disabled(model.isBusy)
                        .accessibilityLabel("Choose destination folder")
                }
            }
            if let advice = model.error(for: .destination) { FieldErrorView(advice: advice) }

            Toggle("Prevent sleep while downloading", isOn: $model.preventSleep)
                .disabled(model.isBusy)
                .help("Keeps the Mac awake while files download. Closing the lid still sleeps.")
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where to save the share. Avoid iCloud Drive."
        panel.directoryURL = model.destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setDestination(url) }
    }
}

/// The main command buttons.
struct ActionsSection: View {
    @Bindable var model: DownloadViewModel

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Button("Connect / List", systemImage: "network", action: model.startConnect)
                    .disabled(!model.canStart)
                    .help("Log in and list every file in the share.")
                Button("Download All", systemImage: "arrow.down.circle", action: model.startDownload)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                    .keyboardShortcut(.defaultAction)
                Button(model.isUserPaused ? "Resume" : "Pause",
                       systemImage: model.isUserPaused ? "play.fill" : "pause.fill") {
                    Task { await model.togglePause() }
                }
                .disabled(!model.isRunning)
                Spacer()
                Button("Retry Failed", systemImage: "arrow.clockwise", action: model.startRetryFailed)
                    .disabled(!model.canRetryFailed)
                Button("Verify", systemImage: "checkmark.shield", action: model.startVerify)
                    .disabled(!model.canVerify)
                    .help("Re-check sizes of completed files on disk. No network needed.")
                Button("Summary", systemImage: "list.bullet.rectangle") { model.isSummaryPresented = true }
                    .disabled(model.report == nil)
            }
            .labelStyle(.titleAndIcon)
            if let advice = model.error(for: .general) { FieldErrorView(advice: advice) }
        }
    }
}
