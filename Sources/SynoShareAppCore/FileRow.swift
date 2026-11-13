import Foundation
import SynoShareKit

/// One row of the Files window table.
public struct FileRow: Sendable, Equatable, Identifiable {
    /// Remote path (what `repair(paths:)` takes); unique.
    public let id: String
    public let relPath: String
    public let size: Int64
    public let health: FileHealth
    /// Waiting in the repair queue (shown with a symbol and text, not color alone).
    public let isRepairQueued: Bool

    public init(entry: FileEntry) {
        id = entry.record.path
        relPath = entry.record.relPath
        size = entry.record.size
        health = entry.health
        isRepairQueued = entry.record.repairQueued
    }

    /// Sort key for the status column: broken first, then the rest.
    public var healthRank: Int { FileRow.order.firstIndex(of: health) ?? FileRow.order.count }

    /// Status text; always shown next to the symbol (never color alone).
    public var statusTitle: String {
        switch health {
        case .complete: return "Complete"
        case .missing: return "Missing"
        case .sizeMismatch: return "Size mismatch"
        case .checksumMismatch: return "Checksum mismatch"
        case .notDownloaded: return "Not downloaded"
        case .unchecked: return "Unchecked"
        }
    }

    /// SF Symbol name for the status.
    public var statusSymbol: String {
        switch health {
        case .complete: return "checkmark.circle"
        case .missing: return "exclamationmark.triangle"
        case .sizeMismatch: return "ruler"
        case .checksumMismatch: return "number"
        case .notDownloaded: return "arrow.down.circle"
        case .unchecked: return "questionmark.circle"
        }
    }

    private static let order: [FileHealth] = [.missing, .sizeMismatch, .checksumMismatch, .unchecked,
                                               .notDownloaded, .complete]
}

/// The status filter of the Files window.
public enum HealthSegment: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case broken = "Broken"
    case missing = "Missing"
    case size = "Size"
    case checksum = "Checksum"
    case unchecked = "Unchecked"
    case ok = "OK"

    public var id: String { rawValue }

    /// Health values shown; empty means every file.
    public var health: Set<FileHealth> {
        switch self {
        case .all: return []
        case .broken: return FileHealth.broken
        case .missing: return [.missing]
        case .size: return [.sizeMismatch]
        case .checksum: return [.checksumMismatch]
        case .unchecked: return [.unchecked]
        case .ok: return [.complete]
        }
    }
}

/// Why the Files table is empty.
public enum FilesEmptyState: Sendable, Equatable {
    case noState
    case noMatches
}
