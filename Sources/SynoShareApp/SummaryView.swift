import SwiftUI
import SynoShareAppCore
import SynoShareKit

/// The job report (and the last verification) in a sheet.
struct SummaryView: View {
    let model: DownloadViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Summary").font(.title2.bold())
            if let report = model.report {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    ForEach(SummaryRows.rows(for: report), id: \.title) { row in
                        GridRow {
                            Text(row.title).foregroundStyle(.secondary)
                            Text(row.value).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Text("No download state yet. Click Connect / List first.").foregroundStyle(.secondary)
            }
            if let verification = model.verification {
                Label("Verified \(verification.checked) completed file(s): \(verification.ok) OK, "
                      + "\(verification.problems.count) problem(s).",
                      systemImage: verification.problems.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                ForEach(verification.problems.prefix(20), id: \.relPath) { problem in
                    Text("\(problem.relPath): \(problem.message)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Label(Report.integrityNote, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }
}
