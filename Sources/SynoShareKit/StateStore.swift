import Foundation

/// Persistent job state at `<dest>/.synoshare/state.sqlite` (WAL mode).
///
/// Holds the listing and per-file progress so that listing and downloading both
/// resume after a crash, Ctrl-C or drive loss. Never stores the password or cookies.
public final class StateStore: @unchecked Sendable {
    public static let directoryName = ".synoshare"
    public static let databaseName = "state.sqlite"

    public let destination: URL
    let db: SQLiteDatabase

    private init(destination: URL, db: SQLiteDatabase) {
        self.destination = destination
        self.db = db
    }

    /// Opens (and with `create`, creates) the state database of `destination`.
    /// The destination folder itself may be reached through a symlink the user chose
    /// (e.g. `/var` → `/private/var`); everything below it is checked with `lstat`.
    public static func open(destination requested: URL, create: Bool = true) throws -> StateStore {
        let destination = SafeFS.canonical(requested)
        let directory = stateDirectory(for: destination)
        let file = directory.appending(path: databaseName)
        if create {
            _ = try SafeFS.ensureDirectory(root: destination, relative: directoryName)
        } else if (try? SafeFS.regularFileSize(file)) == nil {
            throw StateStoreError("No download state found in \(destination.path).")
        }
        let store = StateStore(destination: destination, db: try SQLiteDatabase(path: file.path))
        try store.migrate()
        return store
    }

    public static func stateDirectory(for destination: URL) -> URL {
        destination.appending(path: directoryName, directoryHint: .isDirectory)
    }

    private func migrate() throws {
        _ = try db.query("PRAGMA journal_mode=WAL")
        try db.execute("""
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS job(
                id INTEGER PRIMARY KEY CHECK (id = 1),
                share_server_id TEXT NOT NULL, share_link_id TEXT NOT NULL,
                dest TEXT NOT NULL, root TEXT, created_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS folder(
                path TEXT PRIMARY KEY, parent TEXT, local_path TEXT NOT NULL,
                listed INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS file(
                path TEXT PRIMARY KEY, parent TEXT NOT NULL, rel_path TEXT NOT NULL,
                local_path TEXT NOT NULL, size INTEGER NOT NULL, mtime INTEGER,
                status TEXT NOT NULL, bytes_done INTEGER NOT NULL DEFAULT 0,
                attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, verified_at REAL,
                note TEXT, replace_ok INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS file_status ON file(status);
            CREATE INDEX IF NOT EXISTS file_parent ON file(parent);
            CREATE INDEX IF NOT EXISTS folder_parent ON folder(parent);
            PRAGMA user_version = 1;
            """)
    }

    // MARK: - Job

    public func job() throws -> JobInfo? {
        guard let row = try db.query("SELECT * FROM job WHERE id = 1").first else { return nil }
        return JobInfo(serverID: row.text("share_server_id") ?? "", linkID: row.text("share_link_id") ?? "",
                       destination: row.text("dest") ?? "", root: row.text("root"),
                       createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0))
    }

    /// Binds this destination to `link`, refusing to mix two shares in one state DB.
    public func bind(to link: ShareLink) throws {
        if let existing = try job() {
            guard existing.serverID == link.serverID, existing.linkID == link.linkID else {
                throw StateStoreError("This destination already holds a download from a different share link.")
            }
            return
        }
        try db.query("INSERT INTO job(id, share_server_id, share_link_id, dest, created_at) VALUES (1, ?, ?, ?, ?)",
                     [.text(link.serverID), .text(link.linkID), .text(destination.path), SQLValue(Date())])
    }

    func setRoot(_ root: String) throws {
        try db.query("UPDATE job SET root = ? WHERE id = 1", [.text(root)])
        try db.query("INSERT OR IGNORE INTO folder(path, parent, local_path, listed) VALUES (?, NULL, '', 0)",
                     [.text(root)])
    }

    // MARK: - Folders

    public func folders() throws -> [FolderRecord] {
        try db.query("SELECT * FROM folder ORDER BY path").map(FolderRecord.init(row:))
    }

    func nextUnlistedFolder() throws -> FolderRecord? {
        try db.query("SELECT * FROM folder WHERE listed = 0 ORDER BY path LIMIT 1").first.map(FolderRecord.init(row:))
    }

    /// Marks every folder unlisted so the next listing walks the whole share again
    /// (to find new files and files changed on the server).
    func resetListing() throws {
        try db.query("UPDATE folder SET listed = 0")
    }

    public var isListingComplete: Bool {
        get throws {
            let rows = try db.query("SELECT COUNT(*) AS n, SUM(listed = 0) AS open FROM folder")
            guard let row = rows.first else { return false }
            return (row.int("n") ?? 0) > 0 && (row.int("open") ?? 0) == 0
        }
    }

    /// Remote path → local path of every tracked child of `folder`.
    func childLocalPaths(of folder: String) throws -> [String: String] {
        let rows = try db.query("""
            SELECT path, local_path FROM folder WHERE parent = ?
            UNION ALL SELECT path, local_path FROM file WHERE parent = ? AND status != 'skipped_unsafe'
            """, [.text(folder), .text(folder)])
        var result: [String: String] = [:]
        for row in rows { if let path = row.text("path"), let local = row.text("local_path") { result[path] = local } }
        return result
    }

    /// Records one listed folder atomically: subfolders, files, and the folder's `listed` flag.
    /// Returns the files whose server copy changed, with their state before the change.
    func applyListing(folder: String, entries: [MappedEntry]) throws -> [FileRecord] {
        try db.transaction {
            var changed: [FileRecord] = []
            for mapped in entries {
                if let previous = try record(mapped, parent: folder) { changed.append(previous) }
            }
            try db.query("UPDATE folder SET listed = 1 WHERE path = ?", [.text(folder)])
            return changed
        }
    }

    private func record(_ mapped: MappedEntry, parent: String) throws -> FileRecord? {
        let entry = mapped.entry
        guard let local = mapped.localPath else {
            let note = entry.isDirectory ? "unsafe folder name; contents skipped" : "unsafe file name"
            try db.query("""
                INSERT OR IGNORE INTO file(path, parent, rel_path, local_path, size, mtime, status, note)
                VALUES (?, ?, ?, '', ?, ?, 'skipped_unsafe', ?)
                """, [.text(entry.path), .text(parent), .text(mapped.relPath), .integer(entry.size),
                      SQLValue(Self.seconds(entry.modified)), .text(note)])
            return nil
        }
        if entry.isDirectory {
            try db.query("INSERT OR IGNORE INTO folder(path, parent, local_path, listed) VALUES (?, ?, ?, 0)",
                         [.text(entry.path), .text(parent), .text(local)])
            return nil
        }
        return try upsertFile(mapped, local: local, parent: parent)
    }

    /// New file → pending. Known file whose size or mtime changed → see `changedStatus(from:)`.
    private func upsertFile(_ mapped: MappedEntry, local: String, parent: String) throws -> FileRecord? {
        let entry = mapped.entry
        let mtime = Self.seconds(entry.modified)
        guard let existing = try file(entry.path) else {
            let note = mapped.renamed ? "renamed (case-insensitive name collision)" : nil
            try db.query("""
                INSERT INTO file(path, parent, rel_path, local_path, size, mtime, status, note)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
                """, [.text(entry.path), .text(parent), .text(mapped.relPath), .text(local),
                      .integer(entry.size), SQLValue(mtime), SQLValue(note)])
            return nil
        }
        guard existing.size != entry.size || existing.mtime != mtime else { return nil }
        try updateListing(entry.path, size: entry.size, mtime: mtime)
        return existing
    }

    /// Stores a new server size/mtime for a known file and moves it to the state
    /// DECISIONS #8 prescribes: completed copies become `changed_on_server` (never
    /// overwritten); unfinished ones restart from zero (the caller discards the `.part`).
    func updateListing(_ path: String, size: Int64, mtime: Int64?) throws {
        guard let existing = try file(path) else { return }
        let status = Self.changedStatus(from: existing.status)
        try db.query("""
            UPDATE file SET size = ?, mtime = ?, status = ?, bytes_done = 0, replace_ok = 0,
                note = CASE WHEN ? = 'changed_on_server' THEN 'changed on server after completion' ELSE note END
            WHERE path = ?
            """, [.integer(size), SQLValue(mtime), .text(status.rawValue), .text(status.rawValue), .text(path)])
    }

    static func changedStatus(from status: FileStatus) -> FileStatus {
        switch status {
        case .done, .adopted, .changedOnServer: return .changedOnServer
        case .conflict: return .conflict
        case .skippedUnsafe: return .skippedUnsafe
        case .pending, .downloading, .failed: return .pending
        }
    }

    static func seconds(_ date: Date?) -> Int64? { date.map { Int64($0.timeIntervalSince1970.rounded(.down)) } }
}
