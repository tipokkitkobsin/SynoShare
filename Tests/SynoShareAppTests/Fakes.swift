import Foundation
@testable import SynoShareAppCore
@testable import SynoShareKit

/// Scripted stand-in for `DownloadEngine`. `run()` can be held open until `stop()`.
actor FakeEngine: EngineControlling {
    nonisolated let events: AsyncStream<EngineEvent>
    private let sink: AsyncStream<EngineEvent>.Continuation
    var runResult: Result<Report, Error> = .success(.sample())
    var holdRun = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []
    var conflictList: [ConflictItem] = []
    private(set) var resolved: [(String, ConflictResolution)] = []
    private(set) var repairedPaths: [[String]] = []
    var repairResult: Result<RepairSummary, Error> = .success(RepairSummary(repaired: [], stillBroken: []))

    init() {
        (events, sink) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    func configure(runResult: Result<Report, Error>? = nil, holdRun: Bool? = nil, conflicts: [ConflictItem]? = nil) {
        if let runResult { self.runResult = runResult }
        if let holdRun { self.holdRun = holdRun }
        if let conflicts { conflictList = conflicts }
    }

    /// `repair` waits for `stop()`, then takes a moment to settle (like re-verifying files).
    var holdRepair = false

    func configure(repairResult: Result<RepairSummary, Error>? = nil, holdRepair: Bool? = nil) {
        if let repairResult { self.repairResult = repairResult }
        if let holdRepair { self.holdRepair = holdRepair }
    }

    func emit(_ event: EngineEvent) { sink.yield(event) }

    func repair(paths: [String]) async throws -> RepairSummary {
        calls.append("repair")
        repairedPaths.append(paths)
        if holdRepair {
            await withCheckedContinuation { held = $0 }
            try? await Task.sleep(for: .milliseconds(100))
            calls.append("repairSettled")
        }
        return try repairResult.get()
    }

    private func operation(_ name: String) async throws -> Report {
        calls.append(name)
        if holdRun { await withCheckedContinuation { held = $0 } }
        return try runResult.get()
    }

    func list(refresh: Bool) async throws -> Report { try await operation("list") }
    func run() async throws -> Report { try await operation("run") }
    func retryFailed() async throws -> Report { try await operation("retryFailed") }
    func pause() { calls.append("pause") }
    func resume() { calls.append("resume") }

    func stop() {
        calls.append("stop")
        held?.resume()
        held = nil
    }

    func shutdown() {
        calls.append("shutdown")
        sink.finish()
    }

    func report() throws -> Report { try runResult.get() }
    func verify() throws -> VerificationResult { VerificationResult(checked: 2, ok: 2, problems: []) }

    func resolveConflict(path: String, resolution: ConflictResolution) {
        resolved.append((path, resolution))
        conflictList.removeAll { $0.path == path }
    }

    func conflicts() -> [ConflictItem] { conflictList }
}

/// Records what the view model asked the factory for.
final class EngineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var configs: [EngineConfiguration] = []
    private var providers: [PasswordProvider] = []
    let engine = FakeEngine()

    var configurations: [EngineConfiguration] { lock.withLock { configs } }
    var lastProvider: PasswordProvider? { lock.withLock { providers.last } }

    var factory: EngineFactory {
        { configuration, provider in
            self.lock.withLock {
                self.configs.append(configuration)
                self.providers.append(provider)
            }
            return self.engine
        }
    }
}

final class MemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func password(for account: String) throws -> String? { lock.withLock { items[account] } }
    func save(_ password: String, for account: String) throws { lock.withLock { items[account] = password } }
    func delete(account: String) throws { lock.withLock { items[account] = nil } }
    var all: [String: String] { lock.withLock { items } }
}

final class FakeOfflineReader: OfflineJobReading, @unchecked Sendable {
    private let lock = NSLock()
    var stateExists = true
    var storedReport: Report = .sample()
    var storedConflicts: [ConflictItem] = []
    private(set) var resolved: [String] = []
    var storedEntries: [FileEntry] = []
    var deepVerifyResult = DeepVerifyResult(checked: 2, skipped: 0, ok: 1, baselined: 1,
                                            problems: [FileIssue(relPath: "b.bin", message: "checksum mismatch (sha256)")],
                                            cancelled: false)
    /// Deep Verify waits for cancellation instead of finishing.
    var holdDeepVerify = false
    var manifestResult = ManifestImportResult(matched: 1, unknownPaths: ["zz.bin"], invalidLines: 0, mismatched: 0)
    private(set) var deepVerifyRestarts: [Bool] = []
    private(set) var manifestTexts: [String] = []
    var queuedPartBytes: Int64 = 0
    /// What `fileEntries` returns after the repair queue was cleared.
    var entriesAfterClear: [FileEntry]?
    private(set) var queueClears = 0

    func fileEntries(at destination: URL) throws -> [FileEntry] { lock.withLock { storedEntries } }

    func deepVerify(at destination: URL, restart: Bool,
                    progress: @escaping @Sendable (DeepVerifyProgress) -> Void) async throws -> DeepVerifyResult {
        let (hold, result) = lock.withLock { () -> (Bool, DeepVerifyResult) in
            deepVerifyRestarts.append(restart)
            return (holdDeepVerify, deepVerifyResult)
        }
        progress(DeepVerifyProgress(filesDone: 1, filesTotal: 2, relPath: "a.bin"))
        guard hold else { return result }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return DeepVerifyResult(checked: 1, skipped: 0, ok: 1, baselined: 0, problems: [], cancelled: true)
    }

    func importManifest(at destination: URL, text: String) throws -> ManifestImportResult {
        lock.withLock {
            manifestTexts.append(text)
            return manifestResult
        }
    }

    func queuedRepairPartBytes(at destination: URL) throws -> Int64 { lock.withLock { queuedPartBytes } }

    func clearRepairQueue(at destination: URL) throws {
        lock.withLock {
            queueClears += 1
            if let entriesAfterClear { storedEntries = entriesAfterClear }
        }
    }

    func hasState(at destination: URL) -> Bool { lock.withLock { stateExists } }
    func report(at destination: URL) throws -> Report { lock.withLock { storedReport } }
    func conflicts(at destination: URL) throws -> [ConflictItem] { lock.withLock { storedConflicts } }
    func verify(at destination: URL) throws -> VerificationResult { VerificationResult(checked: 1, ok: 0, problems: [
        FileIssue(relPath: "a.bin", message: "missing")]) }

    func resolveConflict(at destination: URL, path: String, resolution: ConflictResolution) throws {
        lock.withLock {
            resolved.append(path)
            storedConflicts.removeAll { $0.path == path }
        }
    }
}

extension FileEntry {
    /// A tracked file under share root `/S` with the given health.
    static func fake(_ relPath: String, _ health: FileHealth, size: Int64 = 100, queued: Bool = false) -> FileEntry {
        var columns: [String: SQLValue] = [
            "path": .text("/S/\(relPath)"), "parent": .text("/S"), "rel_path": .text(relPath),
            "local_path": .text(relPath), "size": .integer(size), "repair_queued": .integer(queued ? 1 : 0),
        ]
        switch health {
        case .complete:
            columns["status"] = .text("done")
            columns["sha256"] = .text(String(repeating: "a", count: 64))
            columns["hashed_at"] = .real(1000)
        case .unchecked: columns["status"] = .text("done")
        case .missing:
            columns["status"] = .text("pending")
            columns["last_error"] = .text(StateStore.verifyPrefix + "missing")
        case .sizeMismatch: columns["status"] = .text("conflict")
        case .checksumMismatch:
            columns["status"] = .text("conflict")
            columns["last_error"] = .text(StateStore.checksumErrorPrefix + " (sha256)")
        case .notDownloaded: columns["status"] = .text("pending")
        }
        let entry = FileEntry(record: FileRecord(row: SQLRow(columns: columns)))
        precondition(entry.health == health, "fake entry for \(health) classified as \(entry.health)")
        return entry
    }
}

extension Report {
    static func sample(failed: [FileIssue] = [], counts: [FileStatus: Int] = [.done: 3, .pending: 1],
                       expected: Int64 = 4_000, completed: Int64 = 3_000) -> Report {
        Report(folders: 2, files: 4, listingComplete: true, expectedBytes: expected,
               expectedOnDiskBytes: 4 * Preflight.clusterSize, completedBytes: completed, counts: counts,
               sizeMismatches: 0, renamed: [], failed: failed, conflicts: [])
    }
}

/// Polls a main-actor condition (engine work hops through actors and tasks).
@MainActor
func eventually(_ condition: () async -> Bool, timeout: Duration = .seconds(3)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
