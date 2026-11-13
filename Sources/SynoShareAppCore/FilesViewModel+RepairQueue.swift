import Foundation
import SynoShareKit

/// Resume Repair and Discard: the files a stopped, failed or interrupted repair left queued
/// are remembered by the engine, so the user never has to select them again.
extension FilesViewModel {
    public var queuedRepairBytes: Int64 { queuedRepairs.reduce(0) { $0 + $1.record.size } }

    /// Files window banner: the queue is not empty and no repair is running.
    public var showsRepairQueueBanner: Bool { !queuedRepairs.isEmpty && !isRepairing }

    /// Main window notice: the queue is not empty and nothing at all is running.
    public var showsMainWindowRepairNotice: Bool { showsRepairQueueBanner && !isBusy && !download.isBusy }

    public var canResumeRepair: Bool { !queuedRepairs.isEmpty && !isBusy && destination != nil }

    /// "2 files waiting to be repaired".
    public var repairQueueTitle: String {
        let count = queuedRepairs.count
        return count == 1 ? "1 file waiting to be repaired" : "\(count) files waiting to be repaired"
    }

    /// "50 bytes, 15 bytes already downloaded".
    public var repairQueueDetail: String {
        "\(Formatting.bytes(queuedRepairBytes)), \(Formatting.bytes(queuedPartBytes)) already downloaded"
    }

    /// Repairs the queued files through the same flow as Repair N (the main download is
    /// paused and stopped first). The user's checkbox selection is left as it is.
    public func resumeRepair() async {
        guard canResumeRepair else { return }
        _ = await runRepair(queuedRepairs.map(\.record.path))
    }

    /// Leaves the queue: each file keeps its current local copy and its `.part`, and is never
    /// replaced unless the user selects it for repair again.
    public func discardRepairQueue() async {
        guard !isBusy, let destination else { return }
        error = nil
        let offline = offline
        do {
            try await Task.detached { try offline.clearRepairQueue(at: destination) }.value
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
        await load()
    }
}
