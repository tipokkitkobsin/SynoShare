import Foundation

public enum PreflightError: Error, LocalizedError, Equatable {
    case insufficientSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .insufficientSpace(let required, let available):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) }
            return "Not enough free space: need \(format(required)) (incl. exFAT cluster slack), have \(format(available))."
        }
    }
}

/// Free-space check before downloading (DECISIONS #2/#3).
///
/// exFAT allocates whole clusters (128 KiB on the destination), so every file
/// costs its size rounded up; a `.part` already holds its rounded-up share.
public enum Preflight {
    public static let clusterSize: Int64 = 128 * 1024
    /// Room for the state DB, its WAL and the log.
    public static let reserve: Int64 = 64 * 1024 * 1024

    public static func roundUp(_ size: Int64, cluster: Int64 = clusterSize) -> Int64 {
        guard size > 0 else { return 0 }
        return (size + cluster - 1) / cluster * cluster
    }

    /// Additional bytes needed to finish `files` (size, bytes already in `.part`).
    public static func remainingBytes(_ files: [(size: Int64, partBytes: Int64)]) -> Int64 {
        files.reduce(0) { $0 + max(0, roundUp($1.size) - roundUp(min($1.partBytes, $1.size))) }
    }

    public static func check(required: Int64, available: Int64) throws {
        let needed = required + reserve
        guard needed <= available else { throw PreflightError.insufficientSpace(required: needed, available: available) }
    }

    public static func availableBytes(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    /// The files still to download in `store`, with their `.part` sizes read from disk.
    static func remainingBytes(store: StateStore) throws -> Int64 {
        let files = try store.files(status: .pending, .downloading, .failed)
        return remainingBytes(files.map { file in
            let local = PathMapper.localURL(destination: store.destination, relative: file.localPath)
            let part = (try? SafeFS.regularFileSize(PathMapper.partURL(for: local))) ?? 0
            return (file.size, part)
        })
    }
}
