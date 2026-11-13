import Foundation

/// Resume or clear the repair queue (see `StateStore+RepairQueue`).
extension DownloadEngine {
    /// Files selected for repair and not repaired yet, with their health.
    public func queuedRepairs() throws -> [FileEntry] {
        try store.queuedRepairs().map(FileEntry.init(record:))
    }

    /// Repairs the queued files again (`.part` files resume with Range). An empty queue
    /// returns an empty summary without connecting.
    public func resumeRepair() async throws -> RepairSummary {
        let paths = try store.queuedRepairs().map(\.path)
        note("resume repair: \(paths.count) queued file(s)")
        return try await repair(paths: paths)
    }

    /// Removes files from the queue (nil = all). They keep their local copy and `.part`,
    /// and are never replaced unless selected for repair again.
    public func clearRepairQueue(paths: [String]? = nil) throws {
        guard !isRunning else { throw StateStoreError("Stop the download or repair before clearing the queue.") }
        try store.clearRepairQueue(paths)
        note("repair queue cleared: \(paths.map { "\($0.count) file(s)" } ?? "all")")
    }

    /// Offline queue listing (no network, no password).
    public static func queuedRepairs(destination: URL) throws -> [FileEntry] {
        try StateStore.open(destination: destination, create: false).queuedRepairs().map(FileEntry.init(record:))
    }

    /// Bytes already in the `.part` files of queued repairs: what Resume Repair keeps (offline).
    public static func queuedRepairPartBytes(destination: URL) throws -> Int64 {
        let store = try StateStore.open(destination: destination, create: false)
        return try store.queuedRepairs().reduce(Int64(0)) { sum, file in
            let local = PathMapper.localURL(destination: store.destination, relative: file.localPath)
            return sum + ((try? SafeFS.regularFileSize(PathMapper.partURL(for: local))) ?? 0)
        }
    }

    /// Offline queue clearing (no network, no password). Run it only while no engine is
    /// downloading into this destination.
    public static func clearRepairQueue(destination: URL, paths: [String]? = nil) throws {
        try StateStore.open(destination: destination, create: false).clearRepairQueue(paths)
    }
}
