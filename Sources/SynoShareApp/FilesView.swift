import SwiftUI
import SynoShareAppCore
import SynoShareKit

/// The Files window: every tracked file with its status, a filter, and repair of the chosen files.
struct FilesView: View {
    @Bindable var model: FilesViewModel
    @State private var isPathListPresented = false
    @State private var isManifestImporterPresented = false
    @State private var isReplaceConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            if model.showsRepairQueueBanner {
                RepairQueueBanner(model: model)
                    .padding(12)
                Divider()
            }
            FilesFilterBar(model: model)
                .padding(12)
            Divider()
            content
            Divider()
            FilesStatusArea(model: model)
                .padding(12)
            Divider()
            actionBar
                .padding(12)
        }
        .task { await model.load() }
        .onChange(of: model.destination) { Task { await model.load() } }
        .sheet(isPresented: $isPathListPresented) { PathListSheet(model: model) }
        .sheet(isPresented: $model.isRepairResultPresented) { RepairResultView(model: model) }
        .fileImporter(isPresented: $isManifestImporterPresented, allowedContentTypes: [.plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.importManifest(from: url) }
        }
        .confirmationDialog(replaceTitle, isPresented: $isReplaceConfirmationPresented) {
            Button("Replace and Repair", role: .destructive) { startRepair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the local copy of files that look intact with a fresh download. "
                 + "The old copy is kept only if the new download fails its checks.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.emptyState {
        case .noState:
            ContentUnavailableView("No Download State Here", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("Choose the destination folder of a download in the main "
                                                     + "window. Files appear after Connect / List."))
                .frame(maxHeight: .infinity)
        case .noMatches:
            ContentUnavailableView("No Files Match", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Choose another status or change the pattern."))
                .frame(maxHeight: .infinity)
        case nil:
            FilesTable(model: model)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("Deep Verify", systemImage: "checkmark.shield") { model.startDeepVerify() }
                .disabled(model.isBusy || !model.hasState)
                .help("Hash every completed file on disk (SHA-256). Resumes where it stopped. No network needed.")
            Button("Import Manifest…", systemImage: "doc.text") { isManifestImporterPresented = true }
                .disabled(model.isBusy || !model.hasState)
                .help("Load a sha256sum or md5sum file made on the server to check files against it.")
            Button("Select from List…", systemImage: "list.bullet.clipboard") { isPathListPresented = true }
                .disabled(!model.hasState)
                .help("Paste or open a list of paths, one per line, and select those files.")
            Spacer()
            Text(model.countsText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(model.repairButtonTitle, systemImage: "wrench.and.screwdriver", action: repairTapped)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRepair)
                .help("Download only the selected files again, check them, and show what was fixed.")
        }
        .labelStyle(.titleAndIcon)
    }

    private var replaceTitle: String {
        let count = model.intactSelectedCount
        return count == 1 ? "Replace 1 file that looks intact?" : "Replace \(count) files that look intact?"
    }

    private func repairTapped() {
        if model.needsReplaceConfirmation {
            isReplaceConfirmationPresented = true
        } else {
            startRepair()
        }
    }

    private func startRepair() { Task { await model.repairSelected() } }
}

/// Status filter, pattern search and the selection buttons.
struct FilesFilterBar: View {
    @Bindable var model: FilesViewModel
    @FocusState private var isPatternFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Status", selection: $model.segment) {
                    ForEach(HealthSegment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Status filter")
                .fixedSize()
                TextField("Pattern", text: $model.globText, prompt: Text("Folder or pattern, e.g. Survey/**/*.las"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isPatternFocused)
                    .accessibilityLabel("Path pattern")
                    .help("* matches within a folder, ** across folders; a folder is folder/**.")
            }
            if let message = model.globError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pattern error: \(message)")
            }
            HStack(spacing: 8) {
                Button("Select All Broken", systemImage: "checklist") { model.selectAllBroken() }
                    .disabled(model.rows.isEmpty)
                    .help("Select every missing, wrong-size or wrong-checksum file shown below.")
                Button("Select All", systemImage: "checkmark.square") { model.selectAllVisible() }
                    .keyboardShortcut(isPatternFocused ? nil : KeyboardShortcut("a"))
                    .disabled(model.rows.isEmpty)
                    .help("Select every file shown below (⌘A).")
                Button("Clear Selection", systemImage: "square") { model.clearSelection() }
                    .disabled(model.selection.isEmpty)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button("Reload", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .labelStyle(.iconOnly)
                    .disabled(model.isBusy)
                    .help("Read the file list again.")
                    .accessibilityLabel("Reload file list")
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
