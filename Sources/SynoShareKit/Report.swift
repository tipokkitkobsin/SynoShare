import Foundation

/// A file that needs the user's attention.
public struct FileIssue: Sendable, Equatable {
    public let relPath: String
    public let message: String
}

/// Summary of a job, built offline from the state database.
public struct Report: Sendable, Equatable {
    public static let integrityNote =
        "Note: files are checked by size only. A size match is not an integrity guarantee; the server offers no checksum."

    public let folders: Int
    public let files: Int
    public let listingComplete: Bool
    /// Sum of listed sizes of downloadable files.
    public let expectedBytes: Int64
    /// The same, rounded up to exFAT clusters.
    public let expectedOnDiskBytes: Int64
    /// Bytes of files complete locally (downloaded or adopted).
    public let completedBytes: Int64
    public let counts: [FileStatus: Int]
    public let sizeMismatches: Int
    public let renamed: [FileIssue]
    public let failed: [FileIssue]
    public let conflicts: [FileIssue]

    public func count(_ status: FileStatus) -> Int { counts[status] ?? 0 }

    public static func make(store: StateStore) throws -> Report {
        let all = try store.files()
        let downloadable = all.filter { $0.status != .skippedUnsafe }
        var counts: [FileStatus: Int] = [:]
        for file in all { counts[file.status, default: 0] += 1 }
        let issue = { (file: FileRecord) in FileIssue(relPath: file.relPath, message: file.lastError ?? file.note ?? "") }
        return Report(
            folders: try store.folders().count,
            files: downloadable.count,
            listingComplete: try store.isListingComplete,
            expectedBytes: downloadable.reduce(0) { $0 + $1.size },
            expectedOnDiskBytes: downloadable.reduce(0) { $0 + Preflight.roundUp($1.size) },
            completedBytes: downloadable.filter { $0.status.isComplete }.reduce(0) { $0 + $1.size },
            counts: counts,
            sizeMismatches: all.filter { $0.lastError?.hasPrefix(StateStore.verifyPrefix) == true }.count,
            renamed: all.filter { $0.status != .skippedUnsafe && $0.localPath != $0.relPath }
                .map { FileIssue(relPath: $0.relPath, message: "saved as \($0.localPath)") },
            failed: all.filter { $0.status == .failed }.map(issue),
            conflicts: all.filter { $0.status == .conflict || $0.status == .changedOnServer }
                .map { FileIssue(relPath: $0.relPath, message: "\($0.status.rawValue): \($0.note ?? "")") })
    }

    public var text: String {
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) }
        var lines = [
            "Folders: \(folders)\(listingComplete ? "" : " (listing incomplete)")",
            "Files: \(files)  expected \(bytes(expectedBytes)) (on exFAT: \(bytes(expectedOnDiskBytes)))",
            "Done: \(count(.done))  adopted (size-only): \(count(.adopted))  complete bytes: \(bytes(completedBytes))",
            "Pending: \(count(.pending) + count(.downloading))  failed: \(count(.failed))",
            "Conflicts: \(count(.conflict))  changed on server: \(count(.changedOnServer))",
            "Skipped (unsafe names): \(count(.skippedUnsafe))  renamed: \(renamed.count)  size mismatches: \(sizeMismatches)",
        ]
        lines += failed.prefix(Self.listLimit).map { "  failed: \($0.relPath) — \($0.message)" }
        lines += conflicts.prefix(Self.listLimit).map { "  conflict: \($0.relPath) — \($0.message)" }
        lines += renamed.prefix(Self.listLimit).map { "  renamed: \($0.relPath) — \($0.message)" }
        lines.append(Self.integrityNote)
        return lines.joined(separator: "\n")
    }

    static let listLimit = 20
}

/// Result of re-checking completed files on disk.
public struct VerificationResult: Sendable, Equatable {
    public let checked: Int
    public let ok: Int
    public let problems: [FileIssue]
}

/// Re-checks every completed file: exists, is a regular file, size matches. No re-download.
public enum Verifier {
    public static func verify(store: StateStore, now: Date = Date()) throws -> VerificationResult {
        let complete = try store.files(status: .done, .adopted)
        var problems: [FileIssue] = []
        for file in complete {
            let url = PathMapper.localURL(destination: store.destination, relative: file.localPath)
            let message: String?
            do {
                switch try SafeFS.regularFileSize(url) {
                case nil: message = "missing"
                case let size? where size != file.size: message = "size \(size), expected \(file.size)"
                default: message = nil
                }
            } catch {
                message = error.localizedDescription
            }
            if let message {
                try store.markVerifyProblem(file.path, message: message)
                problems.append(FileIssue(relPath: file.relPath, message: message))
            } else {
                try store.markVerified(file.path, at: now)
            }
        }
        return VerificationResult(checked: complete.count, ok: complete.count - problems.count, problems: problems)
    }
}
