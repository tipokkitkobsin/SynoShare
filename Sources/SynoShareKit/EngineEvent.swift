import Foundation

/// Why the engine is paused.
public enum PauseReason: String, Sendable, Hashable {
    case user
    /// The destination volume was unmounted (DECISIONS #9): resume when it returns.
    case volumeUnavailable
}

public enum EnginePhase: Sendable, Equatable {
    case idle
    case connecting
    case listing
    case checkingSpace
    case downloading
    case paused(Set<PauseReason>)
    case stopping
    case finished
}

/// A file being transferred right now.
public struct ActiveFile: Sendable, Equatable {
    public let path: String
    public let bytesDone: Int64
    public let size: Int64
}

/// Overall progress, emitted periodically while downloading.
public struct ProgressSnapshot: Sendable, Equatable {
    /// Bytes of all downloadable files (done + remaining).
    public let totalBytes: Int64
    /// Bytes already on disk (completed files and `.part` data).
    public let completedBytes: Int64
    /// Smoothed throughput (EWMA).
    public let bytesPerSecond: Double
    public let active: [ActiveFile]
    public let concurrency: Int

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 1
    }

    /// Seconds to completion at the current speed, nil while unknown.
    public var eta: TimeInterval? {
        bytesPerSecond > 0 ? Double(max(totalBytes - completedBytes, 0)) / bytesPerSecond : nil
    }
}

/// Everything a UI needs to follow the engine. Paths are remote share paths.
public enum EngineEvent: Sendable, Equatable {
    case phase(EnginePhase)
    case listing(foldersListed: Int, filesKnown: Int)
    case fileStarted(path: String, size: Int64)
    case fileFinished(path: String, status: FileStatus)
    case fileRetrying(path: String, attempt: Int, message: String)
    case fileFailed(path: String, message: String)
    case progress(ProgressSnapshot)
    case warning(String)
    case error(String)
}

/// Lock-protected byte counters fed from download callbacks (any thread) and
/// read by the engine's periodic progress tick.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Int64 = 0
    private var total: Int64 = 0
    private var transferred: Int64 = 0
    private var active: [String: ActiveFile] = [:]

    func reset(total: Int64, completed: Int64) {
        lock.withLock {
            self.total = total
            self.completed = completed
            active = [:]
        }
    }

    func begin(_ path: String, size: Int64, already: Int64) {
        lock.withLock { active[path] = ActiveFile(path: path, bytesDone: already, size: size) }
    }

    func add(_ path: String, _ delta: Int64) {
        lock.withLock {
            completed += delta
            if delta > 0 { transferred += delta }
            if let file = active[path] {
                active[path] = ActiveFile(path: path, bytesDone: file.bytesDone + delta, size: file.size)
            }
        }
    }

    /// The file left the active set; `credit` adds bytes that were never streamed (adopted files).
    func end(_ path: String, credit: Int64 = 0) {
        lock.withLock {
            active[path] = nil
            completed += credit
        }
    }

    /// Bytes received since the previous call, for the speed estimate.
    func drainTransferred() -> Int64 {
        lock.withLock {
            defer { transferred = 0 }
            return transferred
        }
    }

    func snapshot(speed: Double, concurrency: Int) -> ProgressSnapshot {
        lock.withLock {
            ProgressSnapshot(totalBytes: total, completedBytes: completed, bytesPerSecond: speed,
                             active: active.values.sorted { $0.path < $1.path }, concurrency: concurrency)
        }
    }
}
