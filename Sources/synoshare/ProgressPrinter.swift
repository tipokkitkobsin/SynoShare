import Foundation
import SynoShareKit

/// Turns engine events into terminal lines, rate-limited so a 59k-file job stays readable.
struct ProgressPrinter {
    static let progressEvery: TimeInterval = 5
    static let listingEvery = 25

    private var lastProgress = Date.distantPast

    mutating func handle(_ event: EngineEvent) {
        switch event {
        case .phase(let phase):
            print("== \(Self.describe(phase)) ==")
        case .listing(let folders, let files):
            if folders % Self.listingEvery == 0 { print("listed \(folders) folder(s), \(files) file(s) known") }
        case .progress(let snapshot):
            guard Date().timeIntervalSince(lastProgress) >= Self.progressEvery else { return }
            lastProgress = Date()
            print(Self.describe(snapshot))
        case .fileRetrying(let path, let attempt, let message):
            printError("retry \(attempt): \(path): \(message)")
        case .fileFailed(let path, let message):
            printError("FAILED: \(path): \(message)")
        case .fileFinished(let path, let status) where status == .conflict:
            printError("conflict (not overwritten): \(path)")
        case .warning(let message):
            printError("warning: \(message)")
        case .error(let message):
            printError("error: \(message)")
        case .fileStarted, .fileFinished:
            break
        }
    }

    static func describe(_ phase: EnginePhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .listing: return "listing"
        case .checkingSpace: return "checking free space"
        case .downloading: return "downloading"
        case .paused(let reasons): return "paused (\(reasons.map(\.rawValue).sorted().joined(separator: ", ")))"
        case .stopping: return "stopping"
        case .finished: return "finished"
        }
    }

    static func describe(_ snapshot: ProgressSnapshot) -> String {
        let percent = String(format: "%.1f%%", snapshot.fractionCompleted * 100)
        let speed = String(format: "%.2f MB/s", snapshot.bytesPerSecond / 1_000_000)
        let eta = snapshot.eta.map { "ETA \(formatDuration($0))" } ?? "ETA --"
        return "\(percent)  \(formatBytes(snapshot.completedBytes)) / \(formatBytes(snapshot.totalBytes))"
            + "  \(speed)  \(eta)  active \(snapshot.active.count)/\(snapshot.concurrency)"
    }
}
