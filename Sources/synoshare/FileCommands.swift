import Foundation
import SynoShareKit

/// `files`, `deep-verify`, `import-manifest` (offline) and `repair` (network).
enum FileCommands {
    static let listLimit = 50

    static func files(_ arguments: Arguments) throws {
        try arguments.requirePositionals(0)
        let destination = try arguments.destination()
        let (entries, list) = try select(arguments, destination: destination, requireAny: false)
        for entry in entries {
            print(FileListing.line(health: entry.health, size: entry.record.size, relPath: entry.record.relPath))
        }
        if let list { FileListing.pathListLines(list, limit: listLimit).forEach { print($0) } }
        print(FileListing.summary(entries.map(\.health)))
    }

    static func deepVerify(_ arguments: Arguments) async throws {
        try arguments.requirePositionals(0)
        let destination = try arguments.destination()
        let restart = arguments.flags.contains("--restart")
        let printer = DeepVerifyPrinter()
        let task = Task {
            try await DownloadEngine.deepVerify(destination: destination, restart: restart, progress: printer.handle)
        }
        let interrupts = InterruptHandler()
        interrupts.install { task.cancel() }
        let result = try await task.value
        print("deep verify: \(result.checked) checked (\(result.skipped) already done), \(result.ok) OK "
              + "(\(result.baselined) new baseline), \(result.problems.count) problem(s)")
        for problem in result.problems.prefix(listLimit) { print("  \(problem.relPath): \(problem.message)") }
        if result.cancelled { print("stopped early; run deep-verify again to resume, or add --restart") }
    }

    static func importManifest(_ arguments: Arguments) throws {
        try arguments.requirePositionals(1)
        let destination = try arguments.destination()
        let url = URL(filePath: (arguments.positionals[0] as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ArgumentError("cannot read manifest as UTF-8 text: \(url.path)")
        }
        let result = try DownloadEngine.importManifest(destination: destination, text: text)
        FileListing.manifestLines(result, limit: listLimit).forEach { print($0) }
    }

    static func repair(_ arguments: Arguments) async throws {
        try arguments.requirePositionals(1)
        let link = try ShareLink(parsing: arguments.positionals[0])
        let destination = try arguments.destination()
        let (entries, list) = try select(arguments, destination: destination, requireAny: true)
        if let list { FileListing.pathListLines(list, limit: listLimit).forEach { print($0) } }
        guard !entries.isEmpty else { throw ArgumentError("no files match the selection; nothing to repair") }
        let bytes = entries.reduce(Int64(0)) { $0 + $1.record.size }
        print("repairing \(entries.count) file(s), \(formatBytes(bytes)); other files are not touched")
        let configuration = EngineConfiguration(link: link, destination: destination)
        let summary = try await Commands.withEngine(configuration) { engine in
            try await engine.repair(paths: entries.map(\.record.path))
        }
        FileListing.repairLines(summary).forEach { print($0) }
    }

    /// Entries chosen by the filter options and/or `--paths-from`, read offline.
    private static func select(_ arguments: Arguments, destination: URL,
                               requireAny: Bool) throws -> (entries: [FileEntry], list: PathListSelection?) {
        let selection = try arguments.selection(requireAny: requireAny)
        let all = try DownloadEngine.fileEntries(destination: destination)
        let filtered = try selection.filter.map { try DownloadEngine.fileEntries(destination: destination, matching: $0) }
        let listText = try selection.pathsFile.map(readPathList)
        return selection.apply(all: all, filtered: filtered ?? all, listText: listText,
                               rootNames: [destination.lastPathComponent])
    }
}

/// Deep Verify progress, at most one line every few seconds.
final class DeepVerifyPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func handle(_ progress: DeepVerifyProgress) {
        let isDue = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(last) >= ProgressPrinter.progressEvery
                || progress.filesDone == progress.filesTotal else { return false }
            last = Date()
            return true
        }
        guard isDue else { return }
        print("hashed \(progress.filesDone)/\(progress.filesTotal): \(progress.relPath)")
    }
}
