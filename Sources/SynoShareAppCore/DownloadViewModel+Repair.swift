import Foundation
import SynoShareKit

/// Repair of selected files (docs/REPAIR_PLAN.md, R3), driven from the Files window.
extension DownloadViewModel {
    /// Stops the main download if it is running (pause, then the same graceful stop as
    /// the Stop path), then downloads only `paths` again through the engine, using the
    /// password in memory like Download All. Throws advice-ready errors.
    public func repairFiles(_ paths: [String]) async throws -> RepairSummary {
        guard !isVerifying, operation != .repair else { throw AdviceError(.busy) }
        await stopMainRunForRepair()
        error = nil
        let engine = try await prepareEngine()
        operation = .repair
        progress = nil
        statusMessage = "Repairing \(paths.count) file(s). Click Download All afterwards to resume the download."
        let task = Task { try await engine.repair(paths: paths) }
        repairTask = task
        defer {
            operation = nil
            repairTask = nil
        }
        let summary = try await task.value
        progress = nil
        await refreshState()
        statusMessage = "Repaired \(summary.repaired.count) file(s); \(summary.stillBroken.count) still broken. "
            + "Click Download All to resume the download."
        return summary
    }

    private func stopMainRunForRepair() async {
        guard let engine, isRunning else { return }
        await engine.pause()
        await engine.stop()
        await activeTask?.value
    }
}
