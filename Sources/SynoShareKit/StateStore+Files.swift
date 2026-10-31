import Foundation

/// Per-file queries and status transitions.
extension StateStore {
    public func file(_ path: String) throws -> FileRecord? {
        try db.query("SELECT * FROM file WHERE path = ?", [.text(path)]).first.map(FileRecord.init(row:))
    }

    public func files(status: FileStatus...) throws -> [FileRecord] {
        try files(in: status)
    }

    /// All files, or only those in `status` when it is not empty.
    public func files(in status: [FileStatus]) throws -> [FileRecord] {
        guard !status.isEmpty else {
            return try db.query("SELECT * FROM file ORDER BY path").map(FileRecord.init(row:))
        }
        let marks = Array(repeating: "?", count: status.count).joined(separator: ",")
        return try db.query("SELECT * FROM file WHERE status IN (\(marks)) ORDER BY path",
                            status.map { .text($0.rawValue) }).map(FileRecord.init(row:))
    }

    public func fileCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM file").first?.int("n") ?? 0)
    }

    public func largestFile() throws -> FileRecord? {
        try db.query("SELECT * FROM file WHERE status != 'skipped_unsafe' ORDER BY size DESC LIMIT 1")
            .first.map(FileRecord.init(row:))
    }

    /// Every local path already used under `parent` (files and folders), for picking free names.
    func takenLocalNames(parentLocal: String) throws -> Set<String> {
        let prefix = parentLocal.isEmpty ? "" : parentLocal + "/"
        let rows = try db.query("""
            SELECT local_path FROM file WHERE local_path LIKE ? ESCAPE '\\'
            UNION ALL SELECT local_path FROM folder WHERE local_path LIKE ? ESCAPE '\\'
            """, [.text(Self.likeEscaped(prefix) + "%"), .text(Self.likeEscaped(prefix) + "%")])
        let direct = rows.compactMap { $0.text("local_path") }
            .filter { !$0.isEmpty && !$0.dropFirst(prefix.count).contains("/") }
        return Set(direct.map { PathMapper.collisionKey(PathMapper.lastComponent($0)) })
    }

    // MARK: - Transitions

    func markDownloading(_ path: String) throws {
        try setStatus(path, .downloading)
    }

    /// A finished file: `done` after a download, `adopted` when an untracked local copy matched.
    func markComplete(_ path: String, status: FileStatus, bytes: Int64, note: String? = nil) throws {
        try db.query("""
            UPDATE file SET status = ?, bytes_done = ?, last_error = NULL, replace_ok = 0,
                note = COALESCE(?, note) WHERE path = ?
            """, [.text(status.rawValue), .integer(bytes), SQLValue(note), .text(path)])
    }

    func markConflict(_ path: String, note: String) throws {
        try db.query("UPDATE file SET status = 'conflict', note = ?, replace_ok = 0 WHERE path = ?",
                     [.text(note), .text(path)])
    }

    /// Records a failed attempt. `final` moves the file to `failed`; otherwise it stays queued.
    func recordFailure(_ path: String, attempts: Int, error: String, final: Bool) throws {
        try db.query("UPDATE file SET status = ?, attempts = ?, last_error = ? WHERE path = ?",
                     [.text(final ? FileStatus.failed.rawValue : FileStatus.downloading.rawValue),
                      .integer(Int64(attempts)), .text(error), .text(path)])
    }

    /// Back to the queue after a pause or stop; `bytes` is what the `.part` holds.
    func markInterrupted(_ path: String, bytes: Int64) throws {
        try db.query("UPDATE file SET status = 'pending', bytes_done = ? WHERE path = ? AND status = 'downloading'",
                     [.integer(bytes), .text(path)])
    }

    /// Crash recovery: anything left `downloading` by a killed process is pending again.
    func resetInterrupted() throws {
        try db.query("UPDATE file SET status = 'pending' WHERE status = 'downloading'")
    }

    /// `retry-failed`: failed files get a fresh attempt budget.
    @discardableResult
    func resetFailed() throws -> Int {
        let count = try db.query("SELECT COUNT(*) AS n FROM file WHERE status = 'failed'").first?.int("n") ?? 0
        try db.query("UPDATE file SET status = 'pending', attempts = 0, last_error = NULL WHERE status = 'failed'")
        return Int(count)
    }

    func setStatus(_ path: String, _ status: FileStatus) throws {
        try db.query("UPDATE file SET status = ? WHERE path = ?", [.text(status.rawValue), .text(path)])
    }

    /// Applies the user's Replace / Keep both choice to a `conflict` or `changed_on_server` file.
    public func resolveConflict(_ path: String, _ resolution: ConflictResolution) throws {
        guard let record = try file(path) else { throw StateStoreError("Unknown file: \(path)") }
        guard record.status == .conflict || record.status == .changedOnServer else {
            throw StateStoreError("\(record.relPath) is not in conflict (status \(record.status.rawValue)).")
        }
        switch resolution {
        case .replace:
            try db.query("""
                UPDATE file SET status = 'pending', replace_ok = 1, attempts = 0, last_error = NULL,
                    note = 'replace existing local file' WHERE path = ?
                """, [.text(path)])
        case .keepBoth:
            let parentLocal = (record.localPath as NSString).deletingLastPathComponent
            var taken = try takenLocalNames(parentLocal: parentLocal)
            taken.formUnion(Self.namesOnDisk(destination: destination, parentLocal: parentLocal))
            let name = PathMapper.uniqueName(PathMapper.lastComponent(record.localPath), taken: taken)
            try db.query("""
                UPDATE file SET status = 'pending', replace_ok = 0, attempts = 0, last_error = NULL,
                    local_path = ?, note = 'kept both; saved as new name' WHERE path = ?
                """, [.text(PathMapper.join(parentLocal, name)), .text(path)])
        }
    }

    // MARK: - Verification

    func markVerified(_ path: String, at date: Date) throws {
        try db.query("UPDATE file SET verified_at = ?, last_error = NULL WHERE path = ?", [SQLValue(date), .text(path)])
    }

    func markVerifyProblem(_ path: String, message: String) throws {
        try db.query("UPDATE file SET verified_at = NULL, last_error = ? WHERE path = ?",
                     [.text(Self.verifyPrefix + message), .text(path)])
    }

    /// A completed file is gone from disk: queue it for a fresh download.
    func requeueMissing(_ path: String) throws {
        try db.query("""
            UPDATE file SET status = 'pending', bytes_done = 0, attempts = 0, verified_at = NULL,
                last_error = ? WHERE path = ?
            """, [.text(Self.verifyPrefix + "missing"), .text(path)])
    }

    /// A completed file has the wrong size on disk: never overwrite, let the user resolve it.
    func markVerifyConflict(_ path: String, message: String) throws {
        try db.query("""
            UPDATE file SET status = 'conflict', note = ?, replace_ok = 0, verified_at = NULL,
                last_error = ? WHERE path = ?
            """, [.text(message), .text(Self.verifyPrefix + message), .text(path)])
    }

    static let verifyPrefix = "verify: "

    // MARK: - Helpers

    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func namesOnDisk(destination: URL, parentLocal: String) -> Set<String> {
        let directory = PathMapper.localURL(destination: destination, relative: parentLocal)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.map(PathMapper.collisionKey))
    }
}
