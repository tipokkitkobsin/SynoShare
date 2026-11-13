import SwiftUI
import SynoShareAppCore
import SynoShareKit

/// Sortable table of files. The checkbox marks a file for repair; the row highlight is the
/// native selection, and Space flips the checkboxes of the highlighted rows.
struct FilesTable: View {
    @Bindable var model: FilesViewModel
    @State private var highlighted: Set<FileRow.ID> = []

    var body: some View {
        Table(model.rows, selection: $highlighted, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                Toggle("", isOn: binding(for: row))
                    .labelsHidden()
                    .accessibilityLabel("Repair \(row.relPath)")
            }
            .width(24)
            TableColumn("Status", value: \.healthRank) { row in
                HStack(spacing: 8) {
                    FileStatusLabel(row: row)
                    if row.isRepairQueued { RepairQueuedMark() }
                }
            }
            .width(min: 120, ideal: 210)
            TableColumn("Path", value: \.relPath) { row in
                Text(row.relPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.relPath)
            }
            TableColumn("Size", value: \.size) { row in
                Text(Formatting.bytes(row.size))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        }
        .onKeyPress(.space) {
            guard !highlighted.isEmpty else { return .ignored }
            model.toggle(highlighted)
            return .handled
        }
        .accessibilityLabel("Files")
    }

    private func binding(for row: FileRow) -> Binding<Bool> {
        Binding(get: { model.isSelected(row.id) }, set: { model.setSelected(row.id, $0) })
    }
}

/// Symbol plus text, so status never depends on color alone.
struct FileStatusLabel: View {
    let row: FileRow

    var body: some View {
        Label {
            Text(row.statusTitle)
        } icon: {
            Image(systemName: row.statusSymbol).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch row.health {
        case .complete: return .green
        case .missing, .sizeMismatch, .checksumMismatch: return .orange
        case .unchecked, .notDownloaded: return .secondary
        }
    }
}
