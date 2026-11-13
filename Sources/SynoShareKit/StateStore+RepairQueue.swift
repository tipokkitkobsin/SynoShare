import Foundation

/// The repair queue (schema v3, `file.repair_queued`): files the user selected for repair
/// stay queued until a repair passes, so a stop, quit, failure or drive loss never makes
/// the user select them again.
extension StateStore {
    /// Every queued file, ordered by remote path.
    func queuedRepairs() throws -> [FileRecord] {
        try db.query("SELECT * FROM file WHERE repair_queued = 1 ORDER BY path").map(FileRecord.init(row:))
    }

    func queueRepair(_ paths: [String]) throws {
        try setRepairQueued(paths, true)
    }

    func unqueueRepair(_ paths: [String]) throws {
        try setRepairQueued(paths, false)
    }

    private func setRepairQueued(_ paths: [String], _ queued: Bool) throws {
        try db.transaction {
            for path in paths {
                try db.query("UPDATE file SET repair_queued = ? WHERE path = ?",
                             [.integer(queued ? 1 : 0), .text(path)])
            }
        }
    }

    /// A process killed during a repair leaves its files pending with permission to replace
    /// them. Those become conflicts again, so only Resume Repair (never Download All) may
    /// replace the old copy, and only after the new bytes pass every check.
    func parkInterruptedRepairs(_ paths: [String]? = nil) throws {
        let (filter, values) = Self.pathFilter(paths)
        try db.query("""
            UPDATE file SET status = 'conflict', replace_ok = 0, note = 'repair interrupted; resume the repair'
            WHERE repair_queued = 1 AND replace_ok = 1 AND status IN ('pending', 'downloading', 'failed')\(filter)
            """, values)
    }

    /// Leaves the queue (nil = every queued file). Each file keeps its current local copy and
    /// its `.part`, and loses any permission to be replaced.
    func clearRepairQueue(_ paths: [String]? = nil) throws {
        try db.transaction {
            try parkInterruptedRepairs(paths)
            let (filter, values) = Self.pathFilter(paths)
            try db.query("UPDATE file SET repair_queued = 0, replace_ok = 0 WHERE repair_queued = 1\(filter)", values)
        }
    }

    /// ` AND path IN (?, …)` for a path list, nothing for nil.
    private static func pathFilter(_ paths: [String]?) -> (String, [SQLValue]) {
        guard let paths else { return ("", []) }
        guard !paths.isEmpty else { return (" AND 0", []) }
        let marks = Array(repeating: "?", count: paths.count).joined(separator: ",")
        return (" AND path IN (\(marks))", paths.map { .text($0) })
    }
}
