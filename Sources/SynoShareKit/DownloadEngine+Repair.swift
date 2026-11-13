import Foundation

/// What a repair run achieved, per selected file.
public struct RepairSummary: Sendable, Equatable {
    /// Relative paths now downloaded again and verified (size and hash).
    public let repaired: [String]
    /// Files still broken, with the reason. Their old local copy is untouched.
    public let stillBroken: [FileIssue]
}

/// The selected files split into those that can be repaired and those that cannot.
struct RepairPlan {
    let targets: [FileRecord]
    let rejected: [FileIssue]
    /// Remote paths of known files that can never be repaired: they leave the queue.
    let unrepairable: [String]

    init(paths: [String], store: StateStore) throws {
        var seen: Set<String> = []
        var targets: [FileRecord] = []
        var rejected: [FileIssue] = []
        var unrepairable: [String] = []
        for path in paths where seen.insert(path).inserted {
            guard let record = try store.file(path) else {
                rejected.append(FileIssue(relPath: path, message: "unknown file"))
                continue
            }
            guard record.status != .skippedUnsafe else {
                rejected.append(FileIssue(relPath: record.relPath, message: "unsafe file name; cannot be saved"))
                unrepairable.append(record.path)
                continue
            }
            targets.append(record)
        }
        self.targets = targets
        self.rejected = rejected
        self.unrepairable = unrepairable
    }
}

/// Repair only the selected files (docs/REPAIR_PLAN.md, R3).
extension DownloadEngine {
    /// Downloads the files with these remote paths again, and nothing else. Selecting a file
    /// is the user's explicit permission to replace its local copy (DECISIONS #8), but only
    /// with a `.part` that passed the size and manifest checks. Every downloaded file is
    /// verified again; files not repaired go back to their previous state.
    ///
    /// Every target joins the repair queue first and leaves it only once it is repaired and
    /// verified, so an interrupted repair can be resumed (`resumeRepair()`).
    ///
    /// The engine must be idle: pause and stop the main download first.
    public func repair(paths: [String]) async throws -> RepairSummary {
        try beginRun()
        defer { endRun() }
        let plan = try RepairPlan(paths: paths, store: store)
        try store.unqueueRepair(plan.unrepairable)
        try store.queueRepair(plan.targets.map(\.path))
        note("repair: \(plan.targets.count) file(s) selected, \(plan.rejected.count) not repairable")
        do {
            try await cancellingOnTaskCancel { try await self.runRepair(plan.targets) }
        } catch {
            _ = try? settle(plan)
            throw error
        }
        return try settle(plan)
    }

    private func runRepair(_ targets: [FileRecord]) async throws {
        guard !targets.isEmpty else { return }
        _ = try await connectedClient()
        for target in targets { try store.prepareRepair(target.path) }
        let ticker = startTicker()
        defer { ticker.cancel() }
        try await downloadLoop(.selection(targets.map(\.path)))
        tick()
    }

    /// Verifies what was downloaded and restores what was not. Files not repaired stay queued.
    private func settle(_ plan: RepairPlan) throws -> RepairSummary {
        var repaired: [String] = []
        var broken = plan.rejected
        for previous in plan.targets {
            guard let current = try store.file(previous.path) else { continue }
            guard current.status == .done else {
                try store.restoreAfterRepair(previous)
                broken.append(FileIssue(relPath: previous.relPath,
                                        message: current.lastError ?? "stopped before it was repaired"))
                continue
            }
            if let issue = try DeepVerifier.verifyFile(current, store: store) {
                try store.queueRepair([current.path])
                broken.append(issue)
            } else {
                repaired.append(current.relPath)
            }
        }
        note("repair finished: \(repaired.count) repaired, \(broken.count) still broken")
        return RepairSummary(repaired: repaired, stillBroken: broken)
    }
}

extension StateStore {
    /// Queues a selected file and allows its local copy to be replaced.
    func prepareRepair(_ path: String) throws {
        try db.query("""
            UPDATE file SET status = 'pending', replace_ok = 1, attempts = 0, last_error = NULL WHERE path = ?
            """, [.text(path)])
    }

    /// A repair that did not succeed leaves the file exactly as it was before
    /// (status, error, note), and withdraws the permission to replace it.
    func restoreAfterRepair(_ previous: FileRecord) throws {
        try db.query("""
            UPDATE file SET status = ?, replace_ok = 0, attempts = ?, last_error = ?, note = ? WHERE path = ?
            """, [.text(previous.status.rawValue), .integer(Int64(previous.attempts)),
                  SQLValue(previous.lastError), SQLValue(previous.note), .text(previous.path)])
    }
}
