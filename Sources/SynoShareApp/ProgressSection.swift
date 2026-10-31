import SwiftUI
import SynoShareAppCore
import SynoShareKit

/// Overall progress, speed, ETA, concurrency and the files in flight.
struct ProgressSection: View {
    let model: DownloadViewModel

    var body: some View {
        Section("Progress") {
            HStack {
                Text(model.phaseDescription).font(.headline)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Text(Formatting.percent(model.fractionCompleted)).monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            ProgressView(value: model.fractionCompleted)
                .accessibilityLabel("Overall progress")
                .accessibilityValue(Formatting.percent(model.fractionCompleted))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    stat("Downloaded", model.bytesTotal > 0
                         ? "\(Formatting.bytes(model.bytesDone)) of \(Formatting.bytes(model.bytesTotal))" : "—")
                    stat("Speed", Formatting.speed(model.progress?.bytesPerSecond ?? 0))
                }
                GridRow {
                    stat("Time left", model.timeLeft)
                    stat("Parallel files", model.progress.map { "\($0.concurrency)" } ?? "—")
                }
                if let listing = model.listing, model.operation != nil {
                    GridRow {
                        stat("Listed", "\(listing.folders) folders, \(listing.files) files")
                    }
                }
            }

            if let message = model.statusMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.progress?.active ?? [], id: \.path) { file in
                ActiveFileRow(file: file)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct ActiveFileRow: View {
    let file: ActiveFile

    private var fraction: Double {
        file.size > 0 ? min(1, Double(file.bytesDone) / Double(file.size)) : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "arrow.down.doc").foregroundStyle(.tint)
                Text(Formatting.fileName(file.path)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Formatting.bytes(file.bytesDone)) / \(Formatting.bytes(file.size))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: fraction).controlSize(.small)
        }
        .help(file.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading \(Formatting.fileName(file.path))")
        .accessibilityValue(Formatting.percent(fraction))
    }
}
