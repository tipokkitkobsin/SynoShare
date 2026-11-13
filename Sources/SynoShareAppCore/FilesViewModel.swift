import Foundation
import Observation
import SynoShareKit

/// State behind the Files window: every tracked file with its health, a filter,
/// the files chosen for repair, and the Deep Verify / manifest / repair actions
/// (see `FilesViewModel+Actions`). Entries are read offline from the destination
/// chosen in the main window.
@MainActor
@Observable
public final class FilesViewModel {
    // MARK: Files and filter

    public private(set) var entries: [FileEntry] = [] {
        didSet {
            sizes = Dictionary(entries.map { ($0.record.path, $0.record.size) }, uniquingKeysWith: { a, _ in a })
            queuedRepairs = entries.filter(\.record.repairQueued)
        }
    }
    /// Files a stopped or failed repair left queued (see `FilesViewModel+RepairQueue`).
    public private(set) var queuedRepairs: [FileEntry] = []
    /// Bytes already in the `.part` files of queued repairs.
    public private(set) var queuedPartBytes: Int64 = 0
    public private(set) var hasState = false
    public private(set) var isLoading = false
    public var segment: HealthSegment = .all {
        didSet { updateRows() }
    }
    public var globText = "" {
        didSet { updateRows() }
    }
    public private(set) var globError: String?
    public var sortOrder: [KeyPathComparator<FileRow>] = [KeyPathComparator(\FileRow.relPath)] {
        didSet { updateRows() }
    }
    /// Visible rows: filtered and sorted.
    public private(set) var rows: [FileRow] = []

    // MARK: Selection

    /// Remote paths chosen for repair. Kept across filter changes.
    public private(set) var selection: Set<String> = []

    // MARK: Action state (see FilesViewModel+Actions)

    public internal(set) var isDeepVerifying = false
    public internal(set) var deepVerifyProgress: DeepVerifyProgress?
    public internal(set) var deepVerifyResult: DeepVerifyResult?
    public internal(set) var manifestResult: ManifestImportResult?
    public var pathListText = ""
    public internal(set) var pathListResult: PathListSelection?
    public internal(set) var isRepairing = false
    public internal(set) var repairSummary: RepairSummary?
    public var isRepairResultPresented = false
    public internal(set) var error: ErrorAdvice?

    // MARK: Dependencies

    public let download: DownloadViewModel
    let offline: any OfflineJobReading
    var deepVerifyTask: Task<Void, Never>?
    private var sizes: [String: Int64] = [:]

    public init(download: DownloadViewModel, offline: any OfflineJobReading = OfflineJobReader()) {
        self.download = download
        self.offline = offline
    }

    public var destination: URL? { download.destination }

    // MARK: Loading

    /// Reads every file's health from the destination's state, off the main thread.
    public func load() async {
        guard let destination, offline.hasState(at: destination) else {
            hasState = false
            entries = []
            queuedPartBytes = 0
            updateRows()
            return
        }
        isLoading = true
        defer { isLoading = false }
        let offline = offline
        do {
            let (loaded, partBytes) = try await Task.detached { () throws -> ([FileEntry], Int64) in
                let loaded = try offline.fileEntries(at: destination)
                let hasQueue = loaded.contains { $0.record.repairQueued }
                return (loaded, hasQueue ? try offline.queuedRepairPartBytes(at: destination) : 0)
            }.value
            entries = loaded
            queuedPartBytes = partBytes
            hasState = true
            let known = Set(entries.map(\.record.path))
            selection = selection.intersection(known)
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
        updateRows()
    }

    public var emptyState: FilesEmptyState? {
        guard rows.isEmpty, !isLoading else { return nil }
        return hasState ? .noMatches : .noState
    }

    // MARK: Selection

    public func isSelected(_ path: String) -> Bool { selection.contains(path) }

    public func setSelected(_ path: String, _ selected: Bool) {
        if selected { selection.insert(path) } else { selection.remove(path) }
    }

    /// Space bar: flips each of these paths.
    public func toggle(_ paths: Set<String>) {
        selection = selection.symmetricDifference(paths)
    }

    public func selectAllVisible() { selection.formUnion(rows.map(\.id)) }

    public func selectAllBroken() { selection.formUnion(rows.filter { $0.health.isBroken }.map(\.id)) }

    public func clearSelection() { selection = [] }

    /// Adds paths chosen elsewhere (a path list).
    func select(_ paths: [String]) { selection.formUnion(paths) }

    /// After a repair, only files that are still broken stay selected.
    func keepSelected(relPaths: Set<String>) {
        let byRel = Dictionary(entries.map { ($0.record.relPath, $0.record.path) }, uniquingKeysWith: { a, _ in a })
        selection = selection.intersection(relPaths.compactMap { byRel[$0] })
    }

    // MARK: Counts

    public var brokenCount: Int { entries.filter(\.health.isBroken).count }
    public var selectedCount: Int { selection.count }
    public var selectedBytes: Int64 { selection.reduce(0) { $0 + (sizes[$1] ?? 0) } }

    /// "3 broken · 2 selected (30 bytes)".
    public var countsText: String {
        "\(brokenCount) broken · \(selectedCount) selected (\(Formatting.bytes(selectedBytes)))"
    }

    /// Selected files whose local copy looks intact; repairing them replaces it.
    public var intactSelectedCount: Int {
        entries.filter { selection.contains($0.record.path) && [.complete, .unchecked].contains($0.health) }.count
    }

    public var needsReplaceConfirmation: Bool { intactSelectedCount > 0 }

    // MARK: Filtering

    private func updateRows() {
        let wanted = segment.health
        let glob = compileGlob()
        rows = entries
            .filter { wanted.isEmpty || wanted.contains($0.health) }
            .filter { glob?.matches($0.record.relPath) ?? true }
            .map(FileRow.init(entry:))
            .sorted(using: sortOrder)
    }

    /// The glob, or nil (with `globError` set when the text is not usable).
    private func compileGlob() -> Glob? {
        let pattern = globText.trimmingCharacters(in: .whitespaces)
        globError = nil
        guard !pattern.isEmpty else { return nil }
        guard !pattern.hasPrefix("/") else {
            globError = "Paths are relative to the share. Remove the leading “/”."
            return nil
        }
        do {
            return try Glob(pattern)
        } catch {
            globError = "This pattern cannot be used: \(error.localizedDescription)"
            return nil
        }
    }
}
