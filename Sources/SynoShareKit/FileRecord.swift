import Foundation

/// Lifecycle of one remote file in the state database (docs/PHASE3_PLAN.md, StateStore).
public enum FileStatus: String, Sendable, CaseIterable, Codable {
    case pending
    case downloading
    case done
    case failed
    case conflict
    case changedOnServer = "changed_on_server"
    case adopted
    case skippedUnsafe = "skipped_unsafe"

    /// Files that still need bytes from the server.
    public var needsDownload: Bool { self == .pending || self == .downloading || self == .failed }

    /// Files whose local copy is considered complete (by size; there is no server checksum).
    public var isComplete: Bool { self == .done || self == .adopted }
}

/// The user's choice for a `conflict` or `changed_on_server` file (DECISIONS #8).
public enum ConflictResolution: String, Sendable, CaseIterable {
    /// Download again and atomically replace the existing local file.
    case replace
    /// Download to a new sibling name `name (2).ext`, leaving the existing file alone.
    case keepBoth = "keep-both"
}

/// One remote file as tracked in the state database.
public struct FileRecord: Sendable, Equatable {
    /// Remote absolute path, the download key.
    public let path: String
    /// Remote parent folder path.
    public let parent: String
    /// Path relative to the share root, as named on the server.
    public let relPath: String
    /// Path relative to the destination, after collision renames.
    public let localPath: String
    public let size: Int64
    /// Server modification time, seconds since 1970.
    public let mtime: Int64?
    public let status: FileStatus
    public let bytesDone: Int64
    public let attempts: Int
    public let lastError: String?
    public let verifiedAt: Date?
    /// Human-readable tag, e.g. `adopted (size-only)` or a rename notice.
    public let note: String?
    /// The user chose Replace for a conflict: the next download may overwrite.
    public let replaceExisting: Bool

    init(row: SQLRow) {
        path = row.text("path") ?? ""
        parent = row.text("parent") ?? ""
        relPath = row.text("rel_path") ?? ""
        localPath = row.text("local_path") ?? ""
        size = row.int("size") ?? 0
        mtime = row.int("mtime")
        status = FileStatus(rawValue: row.text("status") ?? "") ?? .pending
        bytesDone = row.int("bytes_done") ?? 0
        attempts = Int(row.int("attempts") ?? 0)
        lastError = row.text("last_error")
        verifiedAt = row.date("verified_at")
        note = row.text("note")
        replaceExisting = (row.int("replace_ok") ?? 0) != 0
    }

    /// Server modification time as a date, if listed.
    public var modified: Date? { mtime.map { Date(timeIntervalSince1970: Double($0)) } }
}

/// One remote folder as tracked in the state database.
public struct FolderRecord: Sendable, Equatable {
    public let path: String
    public let parent: String?
    public let localPath: String
    public let listed: Bool

    init(row: SQLRow) {
        path = row.text("path") ?? ""
        parent = row.text("parent")
        localPath = row.text("local_path") ?? ""
        listed = (row.int("listed") ?? 0) != 0
    }
}

/// The share this destination is bound to. The link id is stored (it identifies the job)
/// but must never be written to logs.
public struct JobInfo: Sendable, Equatable {
    public let serverID: String
    public let linkID: String
    public let destination: String
    public let root: String?
    public let createdAt: Date
}
