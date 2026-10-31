import Foundation
import Observation
import SynoShareKit

/// A long-running engine operation started from the window.
public enum EngineOperation: String, Sendable {
    case list = "Listing"
    case download = "Downloading"
    case retryFailed = "Retrying failed files"
}

public struct ListingProgress: Sendable, Equatable {
    public let folders: Int
    public let files: Int
}

/// State and actions behind the single SynoShare window. Views only read
/// properties and call methods; all engine plumbing lives here.
@MainActor
@Observable
public final class DownloadViewModel {
    // MARK: Inputs

    public var shareURL: String {
        didSet { preferences.shareURL = shareURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    public var password = "" {
        didSet { passwordBox.set(password) }
    }
    /// Default off (DECISIONS #7). Turning it off deletes the saved item.
    public var rememberPassword = false {
        didSet { if !rememberPassword, oldValue { forgetSavedPassword() } }
    }
    public var preventSleep: Bool {
        didSet { preferences.preventSleep = preventSleep }
    }
    public internal(set) var destination: URL?

    // MARK: Status

    public internal(set) var operation: EngineOperation?
    public internal(set) var isVerifying = false
    public internal(set) var phase: EnginePhase = .idle
    public internal(set) var listing: ListingProgress?
    public internal(set) var progress: ProgressSnapshot?
    public internal(set) var report: Report?
    public internal(set) var conflicts: [ConflictItem] = []
    public internal(set) var verification: VerificationResult?
    public internal(set) var error: ErrorAdvice?
    public internal(set) var statusMessage: String?
    public var isSummaryPresented = false

    // MARK: Dependencies and plumbing

    let preferences: AppPreferences
    let passwordStore: any PasswordStoring
    let offline: any OfflineJobReading
    let makeEngine: EngineFactory
    let passwordBox = PasswordBox()
    var engine: (any EngineControlling)?
    var engineKey: EngineKey?
    var eventTask: Task<Void, Never>?
    var activeTask: Task<Void, Never>?
    var savedPasswordThisRun = false
    var lastRefresh = Date.distantPast
    let refreshInterval: TimeInterval

    public init(preferences: AppPreferences = AppPreferences(),
                passwordStore: any PasswordStoring = KeychainPasswordStore(),
                offline: any OfflineJobReading = OfflineJobReader(),
                makeEngine: @escaping EngineFactory = Engines.live,
                refreshInterval: TimeInterval = 3) {
        self.preferences = preferences
        self.passwordStore = passwordStore
        self.offline = offline
        self.makeEngine = makeEngine
        self.refreshInterval = refreshInterval
        shareURL = preferences.shareURL
        preventSleep = preferences.preventSleep
        destination = preferences.destination
    }

    // MARK: Derived state

    public var isBusy: Bool { operation != nil || isVerifying }
    public var isRunning: Bool { operation != nil }

    public var isUserPaused: Bool {
        if case .paused(let reasons) = phase { return reasons.contains(.user) }
        return false
    }

    public var isDriveUnavailable: Bool {
        if case .paused(let reasons) = phase { return reasons.contains(.volumeUnavailable) }
        return false
    }

    public var failedFiles: [FileIssue] { report?.failed ?? [] }

    public var canStart: Bool { !isBusy }
    public var canRetryFailed: Bool { !isBusy && !failedFiles.isEmpty }
    public var canVerify: Bool { !isBusy && destination != nil && report != nil }

    /// Bytes on disk and total, from live progress while running, else the last report.
    public var bytesDone: Int64 { progress?.completedBytes ?? report?.completedBytes ?? 0 }
    public var bytesTotal: Int64 { progress?.totalBytes ?? report?.expectedBytes ?? 0 }

    /// ETA text; "—" unless actively downloading (a paused speed decays toward zero).
    public var timeLeft: String {
        guard case .downloading = phase else { return "—" }
        return Formatting.eta(progress?.eta)
    }

    public var fractionCompleted: Double {
        if let progress { return progress.fractionCompleted }
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    /// Advice for one control, so errors render next to it.
    public func error(for field: ErrorField) -> ErrorAdvice? {
        if field == .destination, isDriveUnavailable { return .driveUnplugged }
        return error?.field == field ? error : nil
    }

    public var phaseDescription: String {
        switch phase {
        case .idle: return isVerifying ? "Verifying…" : "Idle"
        case .connecting: return "Connecting…"
        case .listing: return "Listing files…"
        case .checkingSpace: return "Checking free space…"
        case .downloading: return "Downloading"
        case .paused(let reasons):
            return reasons.contains(.volumeUnavailable) ? "Paused — drive unavailable" : "Paused"
        case .stopping: return "Stopping…"
        case .finished: return "Finished"
        }
    }

    // MARK: Lifecycle

    /// Called once when the window appears: restore a saved password and show any
    /// progress already recorded at the destination (e.g. by the CLI).
    public func start() async {
        restoreSavedPassword()
        await loadOfflineState()
    }

    public func setDestination(_ url: URL) async {
        guard !isBusy else { return }
        destination = url
        preferences.destination = url
        error = nil
        verification = nil
        await loadOfflineState()
    }

    /// Graceful shutdown for quit: stop the engine, wait for the operation to unwind, end events.
    public func shutdown() async {
        if let engine {
            await engine.stop()
            await activeTask?.value
            await engine.shutdown()
        }
        eventTask?.cancel()
        engine = nil
        engineKey = nil
    }

    // MARK: Actions (views call the non-async wrappers)

    public func startConnect() { launch { await self.connect() } }
    public func startDownload() { launch { await self.download() } }
    public func startRetryFailed() { launch { await self.retryFailed() } }
    public func startVerify() { launch { await self.verify() } }

    public func connect() async {
        await perform(.list) { try await $0.list(refresh: true) }
    }

    public func download() async {
        await perform(.download) { try await $0.run() }
    }

    public func retryFailed() async {
        await perform(.retryFailed) { try await $0.retryFailed() }
    }

    public func togglePause() async {
        guard let engine, isRunning else { return }
        if isUserPaused { await engine.resume() } else { await engine.pause() }
    }

    public func stop() async {
        await engine?.stop()
    }

    public func verify() async {
        guard canVerify, let destination else { return }
        isVerifying = true
        defer { isVerifying = false }
        error = nil
        do {
            if let engine {
                verification = try await engine.verify()
            } else {
                let offline = offline
                verification = try await Task.detached { try offline.verify(at: destination) }.value
            }
            if let verification {
                statusMessage = "Verified \(verification.checked) file(s): \(verification.ok) OK, "
                    + "\(verification.problems.count) problem(s)."
            }
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
        await refreshState()
        isSummaryPresented = true
    }

    public func resolve(_ conflict: ConflictItem, _ resolution: ConflictResolution) async {
        guard let destination else { return }
        do {
            if let engine {
                try await engine.resolveConflict(path: conflict.path, resolution: resolution)
            } else {
                try offline.resolveConflict(at: destination, path: conflict.path, resolution: resolution)
            }
            let verb = resolution == .replace ? "replace" : "keep both copies of"
            statusMessage = "Will \(verb) \(conflict.relPath). Click Download All to apply."
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
        await refreshState()
    }

    public func dismissError() { error = nil }

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        guard activeTask == nil else { return }
        activeTask = Task {
            await body()
            self.activeTask = nil
        }
    }
}
