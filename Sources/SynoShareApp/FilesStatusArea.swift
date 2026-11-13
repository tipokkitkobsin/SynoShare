import SwiftUI
import SynoShareAppCore
import SynoShareKit

/// Progress and results of Deep Verify, manifest import and repair, plus errors.
struct FilesStatusArea: View {
    let model: FilesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let advice = model.error { FieldErrorView(advice: advice) }
            if model.isDeepVerifying { deepVerifyProgress }
            if model.isRepairing { repairProgress }
            if let result = model.deepVerifyResult, !model.isDeepVerifying { deepVerifyLine(result) }
            if let result = model.manifestResult { manifestLine(result) }
            if model.error == nil, !model.isBusy, model.deepVerifyResult == nil, model.manifestResult == nil {
                Label(Report.integrityNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deepVerifyProgress: some View {
        HStack {
            if let progress = model.deepVerifyProgress, progress.filesTotal > 0 {
                ProgressView(value: Double(progress.filesDone), total: Double(progress.filesTotal)) {
                    Text("Deep Verify: \(progress.filesDone) of \(progress.filesTotal) files").monospacedDigit()
                } currentValueLabel: {
                    Text(progress.relPath).lineLimit(1).truncationMode(.middle)
                }
            } else {
                ProgressView("Deep Verify: preparing…").controlSize(.small)
            }
            Button("Stop", systemImage: "stop.fill") { model.cancelDeepVerify() }
                .help("Stop hashing. The next Deep Verify continues where this one stopped.")
        }
    }

    private var repairProgress: some View {
        let download = model.download
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Repair: \(download.phaseDescription)")
                ProgressView().controlSize(.small)
                Spacer()
                if let progress = download.progress {
                    Text("\(Formatting.bytes(progress.completedBytes)) of \(Formatting.bytes(progress.totalBytes))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(download.progress?.active ?? [], id: \.path) { ActiveFileRow(file: $0) }
        }
    }

    private func deepVerifyLine(_ result: DeepVerifyResult) -> some View {
        let text = "Deep Verify \(result.cancelled ? "stopped" : "finished"): \(result.checked) checked, "
            + "\(result.ok) OK (\(result.baselined) new baseline), \(result.problems.count) problem(s)."
            + (result.cancelled ? " Click Deep Verify to continue." : "")
        return Label(text, systemImage: result.problems.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
            .font(.callout)
    }

    private func manifestLine(_ result: ManifestImportResult) -> some View {
        Label("Manifest: \(result.matched) matched, \(result.mismatched) mismatched, "
              + "\(result.unknownPaths.count) unknown path(s), \(result.invalidLines) invalid line(s). "
              + "Run Deep Verify to check files against it.", systemImage: "doc.text")
            .font(.callout)
            .help(result.unknownPaths.prefix(20).joined(separator: "\n"))
    }
}
