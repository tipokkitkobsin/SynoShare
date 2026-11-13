import Foundation
import SynoShareKit

extension FileHealth {
    /// Kebab-case name used on the command line and in listings.
    var cliName: String {
        rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name += "-" }
            name += character.lowercased()
        }
    }

    /// Accepts the CLI name or the raw value, ignoring case.
    init?(cliName: String) {
        let wanted = cliName.lowercased().replacingOccurrences(of: "-", with: "")
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == wanted }) else { return nil }
        self = match
    }
}

/// Terminal text for `files`, `import-manifest`, `repair`, `repair-queue` and path lists.
enum FileListing {
    static let healthWidth = FileHealth.allCases.map(\.cliName.count).max() ?? 0
    static let sizeWidth = 10

    static func line(health: FileHealth, size: Int64, relPath: String) -> String {
        let name = health.cliName.padding(toLength: healthWidth, withPad: " ", startingAt: 0)
        let sizeText = formatBytes(size)
        let padded = String(repeating: " ", count: max(0, sizeWidth - sizeText.count)) + sizeText
        return "\(name)  \(padded)  \(relPath)"
    }

    /// "4 file(s): 1 complete, 2 missing, 1 unchecked; 2 broken".
    static func summary(_ healths: [FileHealth]) -> String {
        guard !healths.isEmpty else { return "0 file(s)" }
        let counts = Dictionary(grouping: healths, by: { $0 }).mapValues(\.count)
        let parts = FileHealth.allCases.compactMap { health in counts[health].map { "\($0) \(health.cliName)" } }
        let broken = healths.filter(\.isBroken).count
        return "\(healths.count) file(s): \(parts.joined(separator: ", ")); \(broken) broken"
    }

    static func manifestLines(_ result: ManifestImportResult, limit: Int) -> [String] {
        let head = "manifest: \(result.matched) matched, \(result.mismatched) already mismatched, "
            + "\(result.unknownPaths.count) unknown path(s), \(result.invalidLines) invalid line(s)"
        return [head] + limited(result.unknownPaths.map { "  unknown: \($0)" }, limit: limit)
    }

    static func repairLines(_ summary: RepairSummary) -> [String] {
        ["repair: \(summary.repaired.count) repaired, \(summary.stillBroken.count) still broken"]
            + summary.repaired.map { "  repaired: \($0)" }
            + summary.stillBroken.map { "  still broken: \($0.relPath): \($0.message)" }
    }

    /// "2 file(s) waiting to be repaired, 3 KB (1 KB already downloaded)" and one line per file.
    static func queueLines(_ files: [(health: FileHealth, size: Int64, relPath: String)], partBytes: Int64,
                           limit: Int) -> [String] {
        guard !files.isEmpty else { return ["no files are waiting to be repaired"] }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let head = "\(files.count) file(s) waiting to be repaired, \(formatBytes(total)) "
            + "(\(formatBytes(partBytes)) already downloaded)"
        return [head] + limited(files.map { line(health: $0.health, size: $0.size, relPath: $0.relPath) }, limit: limit)
    }

    static func pathListLines(_ selection: PathListSelection, limit: Int) -> [String] {
        let head = "path list: \(selection.matched.count) matched, \(selection.unmatched.count) not found, "
            + "\(selection.sizeDifferences.count) size difference(s)"
        let sizes = selection.sizeDifferences.map {
            "  size differs: \($0.relPath): listed \($0.listed) bytes, recorded \($0.recorded) bytes"
        }
        return [head] + limited(selection.unmatched.map { "  not found: \($0)" }, limit: limit)
            + limited(sizes, limit: limit)
    }

    private static func limited(_ lines: [String], limit: Int) -> [String] {
        guard lines.count > limit else { return lines }
        return Array(lines.prefix(limit)) + ["  ... and \(lines.count - limit) more"]
    }
}
