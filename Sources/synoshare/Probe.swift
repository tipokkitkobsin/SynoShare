import CryptoKit
import Foundation
import SynoShareKit

/// Phase 2 feasibility probe: resolve, login, walk, size check, and a
/// two-part Range download compared byte-for-byte with a full download.
struct Probe {
    let link: ShareLink
    let destination: URL
    let password: String

    static let clusterSize: Int64 = 128 * 1024
    static let preferredTestSize: ClosedRange<Int64> = (64 * 1024)...(8 * 1024 * 1024)
    static let progressEvery = 25

    func run() async throws {
        let session = ShareClient.makeSession()

        step(1, "Resolve QuickConnect")
        let endpoint = try await QuickConnect.resolve(link, session: session)
        say("relay host: \(endpoint.baseURL.host ?? "?") (region \(endpoint.relayRegion))")

        step(2, "Login with share password")
        let client = ShareClient(link: link, endpoint: endpoint, session: session)
        try await client.login(password: password)
        say("login OK (session cookie held in memory only)")
        let root = try await client.openRoot()
        say("share root: \(root)")

        step(3, "List all folders recursively")
        let (files, folderCount, maxDepth) = try await walk(client, root: root)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let onDisk = files.reduce(Int64(0)) { $0 + Self.roundUp($1.size) }
        say("folders: \(folderCount), files: \(files.count), max depth: \(maxDepth)")
        say("total size: \(bytes(total)); on exFAT (128 KB clusters): \(bytes(onDisk))")
        if let largest = files.max(by: { $0.size < $1.size }) {
            say("largest file: \(bytes(largest.size))")
        }

        step(4, "Free space on destination")
        let free = try freeSpace(destination)
        say("free: \(bytes(free)) -> \(free > onDisk ? "FITS" : "DOES NOT FIT")")

        step(5, "Download test with interruption and Range resume")
        guard let test = pickTestFile(files) else {
            say("no non-empty file found; skipping download test")
            return
        }
        try await rangeTest(client, file: test)
    }

    // MARK: - Steps

    private func walk(_ client: ShareClient, root: String) async throws -> ([ShareEntry], Int, Int) {
        var stack: [(String, Int)] = [(root, 0)]
        var files: [ShareEntry] = []
        var folders = 0
        var maxDepth = 0
        var visited = 0
        while let (folder, depth) = stack.popLast() {
            let entries = try await client.list(folder: folder)
            visited += 1
            for entry in entries {
                if entry.isDirectory {
                    folders += 1
                    maxDepth = max(maxDepth, depth + 1)
                    stack.append((entry.path, depth + 1))
                } else {
                    files.append(entry)
                }
            }
            if visited % Self.progressEvery == 0 {
                say("... \(visited) folders listed, \(files.count) files so far")
            }
        }
        return (files, folders, maxDepth)
    }

    private func pickTestFile(_ files: [ShareEntry]) -> ShareEntry? {
        let preferred = files.filter { Self.preferredTestSize.contains($0.size) }
        return preferred.min(by: { $0.size < $1.size }) ?? files.filter { $0.size > 1 }.min(by: { $0.size < $1.size })
    }

    private func rangeTest(_ client: ShareClient, file: ShareEntry) async throws {
        let half = file.size / 2
        say("test file: \(file.name) (\(bytes(file.size)))")
        let probeDir = destination.appending(path: ".probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        let part = probeDir.appending(path: "test.part")
        let final = probeDir.appending(path: "test.bin")
        try? FileManager.default.removeItem(at: part)
        try? FileManager.default.removeItem(at: final)

        let (first, r1) = try await client.fetch(remotePath: file.path, range: "0-\(half - 1)")
        say("part 1: HTTP \(r1.statusCode), \(first.count) bytes, Content-Range: \(r1.value(forHTTPHeaderField: "Content-Range") ?? "none")")
        guard r1.statusCode == 206, Int64(first.count) == half else {
            say("RESULT: server did NOT honour Range -> resume unsupported, files must restart on failure")
            return
        }
        try first.write(to: part)
        say("simulated interruption: .part holds \(bytes(half)) of \(bytes(file.size))")

        let (rest, r2) = try await client.fetch(remotePath: file.path, range: "\(half)-")
        say("part 2: HTTP \(r2.statusCode), \(rest.count) bytes, Content-Range: \(r2.value(forHTTPHeaderField: "Content-Range") ?? "none")")
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        try handle.write(contentsOf: rest)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: part, to: final)

        let resumed = try Data(contentsOf: final)
        let started = Date()
        let (full, _) = try await client.fetch(remotePath: file.path)
        let seconds = Date().timeIntervalSince(started)
        let sizeOK = Int64(resumed.count) == file.size
        let hashOK = SHA256.hash(data: resumed) == SHA256.hash(data: full)
        say("size check: \(resumed.count) vs listed \(file.size) -> \(sizeOK ? "MATCH" : "MISMATCH")")
        say("SHA-256 resumed vs fresh full download -> \(hashOK ? "IDENTICAL" : "DIFFERENT")")
        say(String(format: "full download speed: %.2f MB/s", Double(full.count) / max(seconds, 0.001) / 1_000_000))
        say("RESULT: \(sizeOK && hashOK ? "Range resume WORKS" : "Range resume FAILED")")
        try? FileManager.default.removeItem(at: final)
    }

    // MARK: - Helpers

    private func freeSpace(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    static func roundUp(_ size: Int64) -> Int64 {
        guard size > 0 else { return 0 }
        return (size + clusterSize - 1) / clusterSize * clusterSize
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }

    private func step(_ number: Int, _ title: String) { print("\n[\(number)] \(title)") }
    private func say(_ text: String) { print("    \(text)") }
}
