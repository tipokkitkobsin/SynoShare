import SwiftUI
import SynoShareAppCore
import SynoShareKit

/// Failed files and conflicts that need the user's attention.
struct IssuesSection: View {
    let model: DownloadViewModel
    @State private var pendingReplace: ConflictItem?

    var body: some View {
        if !model.failedFiles.isEmpty {
            Section("Failed (\(model.failedFiles.count))") {
                ForEach(model.failedFiles, id: \.relPath) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(issue.relPath, systemImage: "xmark.octagon.fill")
                            .symbolRenderingMode(.multicolor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Failed: \(issue.relPath). \(issue.message)")
                }
            }
        }

        if !model.conflicts.isEmpty {
            Section {
                ForEach(model.conflicts) { conflict in
                    ConflictRow(conflict: conflict, isBusy: model.isRunning,
                                onReplace: { pendingReplace = conflict },
                                onKeepBoth: { resolve(conflict, .keepBoth) })
                }
            } header: {
                Text("Conflicts (\(model.conflicts.count))")
            } footer: {
                Text("A local file differs from the server. Nothing is overwritten until you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog("Replace the local file?", isPresented: replaceBinding, presenting: pendingReplace) { conflict in
                Button("Replace", role: .destructive) { resolve(conflict, .replace) }
                Button("Cancel", role: .cancel) {}
            } message: { conflict in
                Text("\(conflict.relPath) will be downloaded again and replace the file on disk.")
            }
        }
    }

    private var replaceBinding: Binding<Bool> {
        Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } })
    }

    private func resolve(_ conflict: ConflictItem, _ resolution: ConflictResolution) {
        Task { await model.resolve(conflict, resolution) }
    }
}

struct ConflictRow: View {
    let conflict: ConflictItem
    let isBusy: Bool
    let onReplace: () -> Void
    let onKeepBoth: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(conflict.relPath, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(conflict.detail).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Replace", action: onReplace)
                .accessibilityLabel("Replace \(conflict.relPath)")
            Button("Keep Both", action: onKeepBoth)
                .accessibilityLabel("Keep both copies of \(conflict.relPath)")
        }
        .disabled(isBusy)
    }
}
