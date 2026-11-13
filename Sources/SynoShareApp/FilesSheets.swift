import SwiftUI
import SynoShareAppCore
import SynoShareKit

/// "Select from List…": paste or open a list of paths (one per line) and select those files.
struct PathListSheet: View {
    @Bindable var model: FilesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Files from a List").font(.title2)
            Text("One path per line, relative to the share. Blank lines and lines starting with # are "
                 + "ignored; a trailing size such as (1,234 bytes) is allowed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.pathListText)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .border(.separator)
                .accessibilityLabel("Paths, one per line")
            if let result = model.pathListResult { PathListResultView(result: result) }
            HStack {
                Button("Choose File…", systemImage: "folder") { isImporterPresented = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Select Listed Files") { model.applyPathList() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pathListText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.loadPathList(from: url) }
        }
    }
}

struct PathListResultView: View {
    let result: PathListSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(result.matched.count) matched and selected, \(result.unmatched.count) not found, "
                  + "\(result.sizeDifferences.count) size difference(s).",
                  systemImage: result.unmatched.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .monospacedDigit()
            if !result.unmatched.isEmpty || !result.sizeDifferences.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(result.unmatched.enumerated()), id: \.offset) { _, line in
                            Text("Not found: \(line)")
                        }
                        ForEach(result.sizeDifferences, id: \.relPath) { difference in
                            Text("Size differs: \(difference.relPath) — listed \(difference.listed) bytes, "
                                 + "recorded \(difference.recorded) bytes")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .font(.callout)
    }
}

/// Result of a repair: what was fixed, what is still broken and why.
struct RepairResultView: View {
    let model: FilesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repair Finished").font(.title2)
            if let summary = model.repairSummary {
                Label("\(summary.repaired.count) repaired, \(summary.stillBroken.count) still broken",
                      systemImage: summary.stillBroken.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.headline)
                List {
                    if !summary.repaired.isEmpty {
                        Section("Repaired") {
                            ForEach(summary.repaired, id: \.self) { path in
                                Label(path, systemImage: "checkmark.circle")
                            }
                        }
                    }
                    if !summary.stillBroken.isEmpty {
                        Section("Still broken") {
                            ForEach(summary.stillBroken, id: \.relPath) { issue in
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(issue.relPath)
                                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle")
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 200)
            }
            Label("The main download stays stopped. Click Download All in the main window to resume it.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 380)
    }
}
