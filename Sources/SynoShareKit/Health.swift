import Foundation

/// How healthy one file's local copy is (docs/REPAIR_PLAN.md). Derived from the
/// state DB only; `verify` and Deep Verify refresh what it is derived from.
public enum FileHealth: String, Sendable, CaseIterable, Codable {
    /// Complete and hashed; the hash matches every known reference.
    case complete
    /// Should be on disk but is not (or the path is not a regular file).
    case missing
    /// The local copy differs from the server in size (or changed on the server).
    case sizeMismatch
    /// The local bytes do not match the recorded or manifest checksum.
    case checksumMismatch
    /// Never finished downloading (pending, failed, unsafe name).
    case notDownloaded
    /// Complete by size but not hashed against every reference yet: run Deep Verify.
    case unchecked

    public static let broken: Set<FileHealth> = [.missing, .sizeMismatch, .checksumMismatch]

    public var isBroken: Bool { Self.broken.contains(self) }

    public init(_ record: FileRecord) {
        if record.lastError?.hasPrefix(StateStore.checksumErrorPrefix) == true {
            self = .checksumMismatch
            return
        }
        switch record.status {
        case .done, .adopted: self = Self.completed(record)
        case .pending, .downloading, .failed:
            self = record.lastError == StateStore.verifyPrefix + "missing" ? .missing : .notDownloaded
        case .conflict, .changedOnServer: self = .sizeMismatch
        case .skippedUnsafe: self = .notDownloaded
        }
    }

    private static func completed(_ record: FileRecord) -> FileHealth {
        if record.lastError?.hasPrefix(StateStore.verifyPrefix) == true { return .missing }
        guard let sha256 = record.sha256, record.hashedAt != nil else { return .unchecked }
        if let expected = record.expectedHash, expected.algorithm == .sha256, expected.hex != sha256 {
            return .checksumMismatch
        }
        return .complete
    }
}

/// One file with its health, for listing and selection.
public struct FileEntry: Sendable, Equatable {
    public let record: FileRecord
    public let health: FileHealth

    public init(record: FileRecord) {
        self.record = record
        health = FileHealth(record)
    }
}

/// Which files to list. Empty health and a nil glob match everything.
public struct FileFilter: Sendable, Equatable {
    public var health: Set<FileHealth>
    /// Matched against `rel_path` (see `Glob`).
    public var glob: String?

    public init(health: Set<FileHealth> = [], glob: String? = nil) {
        self.health = health
        self.glob = glob
    }

    /// A predicate for this filter; throws for a glob that cannot be compiled.
    func matcher() throws -> (FileEntry) -> Bool {
        let compiled = try glob.map(Glob.init)
        let health = health
        return { entry in
            (health.isEmpty || health.contains(entry.health))
                && (compiled?.matches(entry.record.relPath) ?? true)
        }
    }
}

extension StateStore {
    /// Every tracked file with its health, filtered, ordered by remote path.
    public func fileEntries(matching filter: FileFilter = FileFilter()) throws -> [FileEntry] {
        try files().map(FileEntry.init(record:)).filter(try filter.matcher())
    }
}
