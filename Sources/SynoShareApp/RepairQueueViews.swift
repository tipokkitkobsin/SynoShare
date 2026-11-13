import SwiftUI
import SynoShareAppCore

/// Files window banner: files a stopped or failed repair left queued, with Resume Repair
/// and Discard. Shown while the queue is not empty and no repair is running.
struct RepairQueueBanner: View {
    let model: FilesViewModel
    @State private var isDiscardConfirmationPresented = false

    var body: some View {
        HStack(spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.repairQueueTitle).font(.headline)
                    Text(model.repairQueueDetail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            } icon: {
                Image(systemName: RepairQueueSymbol.name).foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Discard…", role: .destructive) { isDiscardConfirmationPresented = true }
                .disabled(model.isBusy)
                .help("Stop remembering these files. Their current local copies are kept.")
            Button("Resume Repair", systemImage: "wrench.and.screwdriver") { Task { await model.resumeRepair() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canResumeRepair)
                .help("Continue repairing these files where the last repair stopped.")
        }
        .confirmationDialog("Discard the repair queue?", isPresented: $isDiscardConfirmationPresented) {
            Button("Discard", role: .destructive) { Task { await model.discardRepairQueue() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files keep their current local copy and are not repaired. Partly downloaded data "
                 + "is kept, so repairing them later continues where it stopped.")
        }
    }
}

/// Main window notice: the repair queue is waiting and nothing is running.
struct RepairQueueNotice: View {
    let files: FilesViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            Label(files.repairQueueTitle, systemImage: RepairQueueSymbol.name)
                .font(.callout)
            Spacer()
            Button("Resume Repair", systemImage: "wrench.and.screwdriver") {
                openWindow(id: FilesWindow.id)
                Task { await files.resumeRepair() }
            }
            .disabled(!files.canResumeRepair)
            .help("Open the Files window and continue repairing these files where the last repair stopped.")
        }
    }
}

/// The table mark for a queued file: symbol plus text, with help.
struct RepairQueuedMark: View {
    var body: some View {
        Label("Queued", systemImage: RepairQueueSymbol.name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Queued for repair. Click Resume Repair to continue.")
            .accessibilityLabel("Queued for repair")
    }
}

enum RepairQueueSymbol {
    static let name = "clock.arrow.circlepath"
}
