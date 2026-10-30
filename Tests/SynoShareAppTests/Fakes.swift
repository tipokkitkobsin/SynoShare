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

    init() {
        (events, sink) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    func configure(runResult: Result<Report, Error>? = nil, holdRun: Bool? = nil, conflicts: [ConflictItem]? = nil) {
        if let runResult { self.runResult = runResult }
        if let holdRun { self.holdRun = holdRun }
        if let conflicts { conflictList = conflicts }
    }

    func emit(_ event: EngineEvent) { sink.yield(event) }

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
