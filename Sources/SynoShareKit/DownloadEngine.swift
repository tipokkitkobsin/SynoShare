import Foundation

/// Supplies the share password when the engine needs to (first login and re-login
/// after session expiry). The engine never stores what it returns.
public typealias PasswordProvider = @Sendable () async throws -> String

/// Tunables and injection points for `DownloadEngine`.
public struct EngineConfiguration: Sendable {
    public var link: ShareLink
    public var destination: URL
    /// Concurrent files (DECISIONS #10). Adaptive down to 1.
    public var maxConcurrency = 3
    /// Hold a power assertion against idle sleep while downloading (DECISIONS #9).
    public var preventSleep = true
    public var retryPolicy = RetryPolicy()
    /// How often progress events are emitted and the destination volume is checked.
    public var tickInterval: Duration = .milliseconds(500)
    public var makeSession: @Sendable () -> URLSession = { ShareClient.makeSession() }
    public var resolveEndpoint: @Sendable (ShareLink, URLSession) async throws -> ShareEndpoint = {
        try await QuickConnect.resolve($0, session: $1)
    }
    /// Overrides the volume check (tests). Nil uses `VolumeProbe`.
    public var volumeAvailable: (@Sendable () -> Bool)?

    public init(link: ShareLink, destination: URL) {
        self.link = link
        self.destination = destination
    }
}

public struct SpeedTestResult: Sendable, Equatable {
    public let bytes: Int64
    public let seconds: Double
    public var megabytesPerSecond: Double { seconds > 0 ? Double(bytes) / seconds / 1_000_000 : 0 }
}

/// The download engine: list, reconcile, preflight, then download with resume,
/// retries, adaptive concurrency, pause/resume and volume-loss handling.
///
/// Drive it with `run()` / `retryFailed()`; control it with `pause()`, `resume()`
/// and `stop()`; observe it through `events`.
public actor DownloadEngine {
    public nonisolated let events: AsyncStream<EngineEvent>
    let eventSink: AsyncStream<EngineEvent>.Continuation
    let configuration: EngineConfiguration
    let passwordProvider: PasswordProvider
    let destination: URL
    let session: URLSession
    let log: EventLog
    let meter = ProgressMeter()
    let power = PowerAssertion()
    let volumeAvailable: @Sendable () -> Bool
    var store: StateStore
    var client: ShareClient?
    var concurrency: AdaptiveConcurrency
    var speed = SpeedEstimator()
    var phase: EnginePhase = .idle
    var pauseReasons: Set<PauseReason> = []
    var isStopping = false
    var isRunning = false
    var passTask: Task<Void, Error>?
    var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    var reloginTask: Task<Void, Error>?
    var sessionGeneration = 0

    public init(configuration: EngineConfiguration, passwordProvider: @escaping PasswordProvider) throws {
        let destination = SafeFS.canonical(configuration.destination)
        let store = try StateStore.open(destination: destination)
        try store.bind(to: configuration.link)
        self.configuration = configuration
        self.passwordProvider = passwordProvider
        self.destination = destination
        self.store = store
        session = configuration.makeSession()
        log = EventLog(directory: StateStore.stateDirectory(for: destination),
                       secrets: [configuration.link.linkID, configuration.link.serverID])
        concurrency = AdaptiveConcurrency(maximum: configuration.maxConcurrency)
        let probe = VolumeProbe(destination: destination)
        volumeAvailable = configuration.volumeAvailable ?? { probe.isAvailable() }
        (events, eventSink) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(4096))
    }

    // MARK: - Public API

    /// Resolves the relay and logs in (asks the password provider).
    public func connect() async throws {
        _ = try await connectedClient()
    }

    /// Lists the share into the state DB. `refresh` re-walks every folder to find new
    /// and changed files; otherwise only an interrupted listing is continued.
    @discardableResult
    public func list(refresh: Bool = true) async throws -> Report {
        try beginRun()
        defer { endRun() }
        try await cancellingOnTaskCancel {
            try await self.listShare(refresh: refresh)
            try self.reconcileExisting()
        }
        return try report()
    }

    /// Downloads everything still pending. Returns when done, stopped, or on a fatal error.
    @discardableResult
    public func run() async throws -> Report {
        try beginRun()
        defer { endRun() }
        try await cancellingOnTaskCancel { try await self.runJob() }
        return try report()
    }

    /// Gives failed files a fresh attempt budget, then runs.
    @discardableResult
    public func retryFailed() async throws -> Report {
        let count = try store.resetFailed()
        note("retry-failed: \(count) file(s) queued again")
        return try await run()
    }

    public func pause() { pause(.user) }

    public func resume() {
        pauseReasons.remove(.user)
        note("resume requested")
        wakeIfUnpaused()
    }

    /// Graceful stop: in-flight chunks are written, state is flushed, `run()` returns.
    public func stop() {
        guard !isStopping else { return }
        isStopping = true
        note("stop requested")
        emit(.phase(.stopping))
        passTask?.cancel()
        wakeAll()
    }

    public func resolveConflict(path: String, resolution: ConflictResolution) throws {
        try store.resolveConflict(path, resolution)
        note("conflict resolved (\(resolution.rawValue)): \(path)")
    }

    public func report() throws -> Report { try Report.make(store: store) }

    /// Files in the given states, e.g. conflicts with their remote `path` for `resolveConflict`.
    public func files(status: FileStatus...) throws -> [FileRecord] {
        try store.files(in: status)
    }

    public func verify() throws -> VerificationResult { try Verifier.verify(store: store) }

    /// Ends the `events` stream. Call when the engine is no longer needed.
    public func shutdown() {
        power.release()
        eventSink.finish()
    }

    /// Offline report from a destination's state DB (no network, no password).
    public static func report(destination: URL) throws -> Report {
        try Report.make(store: StateStore.open(destination: destination, create: false))
    }

    /// Offline verification of completed files (no network, no password).
    public static func verify(destination: URL) throws -> VerificationResult {
        try Verifier.verify(store: StateStore.open(destination: destination, create: false))
    }

    // MARK: - Internals shared by the extensions

    func beginRun() throws {
        guard !isRunning else { throw StateStoreError("The engine is already running.") }
        isRunning = true
        isStopping = false
    }

    func endRun() {
        isRunning = false
        power.release()
        setPhase(isStopping ? .idle : .finished)
    }

    /// Cancelling the caller's task (e.g. a SwiftUI `.task`) is treated as a graceful stop.
    func cancellingOnTaskCancel(_ body: () async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try await body()
        } onCancel: {
            Task { await self.stop() }
        }
    }

    func pause(_ reason: PauseReason) {
        guard !pauseReasons.contains(reason) else { return }
        pauseReasons.insert(reason)
        note("paused: \(reason.rawValue)")
        passTask?.cancel()
        setPhase(.paused(pauseReasons))
    }

    func waitUntilResumed() async {
        guard !pauseReasons.isEmpty, !isStopping else { return }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    func wakeIfUnpaused() {
        if pauseReasons.isEmpty { wakeAll() }
    }

    private func wakeAll() {
        let waiters = resumeWaiters
        resumeWaiters = []
        waiters.forEach { $0.resume() }
    }

    func setPhase(_ newPhase: EnginePhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        emit(.phase(newPhase))
    }

    func emit(_ event: EngineEvent) { eventSink.yield(event) }

    func note(_ message: String) { log.write(message) }

    /// A user-facing description of an error, with the link id removed.
    func describe(_ error: Error) -> String {
        EventLog.redact(error.localizedDescription,
                        secrets: [configuration.link.linkID, configuration.link.serverID])
    }

    func localURL(_ file: FileRecord) -> URL {
        PathMapper.localURL(destination: destination, relative: file.localPath)
    }

    func partBytes(_ file: FileRecord) -> Int64 {
        (try? SafeFS.regularFileSize(PathMapper.partURL(for: localURL(file)))) ?? 0
    }
}
