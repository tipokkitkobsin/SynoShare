import Foundation

/// File health listing and Deep Verify (docs/REPAIR_PLAN.md).
extension DownloadEngine {
    /// Every tracked file with its health, filtered.
    public func fileEntries(matching filter: FileFilter = FileFilter()) throws -> [FileEntry] {
        try store.fileEntries(matching: filter)
    }

    /// Hashes completed files from disk (see `DeepVerifier`). Cancelling the calling task
    /// stops it between chunks; the next call resumes unless `restart` is true.
    public nonisolated func deepVerify(restart: Bool = false,
                                       progress: @escaping @Sendable (DeepVerifyProgress) -> Void = { _ in })
        async throws -> DeepVerifyResult {
        try await Self.deepVerify(destination: destination, restart: restart, progress: progress)
    }

    /// Offline file listing (no network, no password).
    public static func fileEntries(destination: URL, matching filter: FileFilter = FileFilter()) throws -> [FileEntry] {
        try StateStore.open(destination: destination, create: false).fileEntries(matching: filter)
    }

    /// Offline Deep Verify (no network, no password).
    public static func deepVerify(destination: URL, restart: Bool = false,
                                  progress: @escaping @Sendable (DeepVerifyProgress) -> Void = { _ in })
        async throws -> DeepVerifyResult {
        let store = try StateStore.open(destination: destination, create: false)
        return try DeepVerifier.run(store: store, restart: restart, isCancelled: { Task.isCancelled },
                                    progress: progress)
    }
}

/// Checksum manifests (`sha256sum` / `md5sum` text).
extension DownloadEngine {
    /// Records the manifest's hashes as each file's expected hash. Unknown paths are reported.
    public func importManifest(_ text: String) throws -> ManifestImportResult {
        let result = try store.importManifest(Manifest.parse(text))
        note("manifest imported: \(result.matched) matched, \(result.unknownPaths.count) unknown")
        return result
    }

    /// Offline manifest import (no network, no password).
    public static func importManifest(destination: URL, text: String) throws -> ManifestImportResult {
        try StateStore.open(destination: destination, create: false).importManifest(Manifest.parse(text))
    }
}
