import Foundation

/// One usable line of a pasted path list.
public struct PathListLine: Sendable, Equatable {
    /// 1-based line number in the original text.
    public let lineNumber: Int
    /// The trimmed line as written, for reporting.
    public let text: String
    /// The path with `./` and the size annotation removed.
    public let path: String
    /// Size from a trailing `(1,234,567,890 bytes)` annotation, if any.
    public let listedSize: Int64?
}

/// A listed size that differs from the recorded one. The file is still selected.
public struct PathListSizeDifference: Sendable, Equatable {
    public let relPath: String
    public let listed: Int64
    public let recorded: Int64

    public init(relPath: String, listed: Int64, recorded: Int64) {
        self.relPath = relPath
        self.listed = listed
        self.recorded = recorded
    }
}

/// What a path list selected.
public struct PathListSelection: Sendable, Equatable {
    /// Matched files, de-duplicated, in list order.
    public let matched: [FileEntry]
    /// Lines that matched no tracked file (as written). Never fatal.
    public let unmatched: [String]
    public let sizeDifferences: [PathListSizeDifference]

    public init(matched: [FileEntry], unmatched: [String], sizeDifferences: [PathListSizeDifference]) {
        self.matched = matched
        self.unmatched = unmatched
        self.sizeDifferences = sizeDifferences
    }

    /// Remote paths of the matched files (what `repair(paths:)` takes).
    public var paths: [String] { matched.map(\.record.path) }
}

/// Selecting files from a list of paths, one per line (pasted or from a file).
/// Blank lines and `#` comments are ignored; `./` and a trailing size annotation are
/// removed; a leading share-root or destination folder name is removed when it is not
/// a real top-level folder. Matching ignores case and Unicode normalisation.
public enum PathList {
    private static let sizeAnnotation = try? NSRegularExpression(
        pattern: #"\s*\(\s*([0-9][0-9,]*)\s*bytes?\s*\)\s*$"#, options: [.caseInsensitive])

    public static func parse(_ text: String) -> [PathListLine] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let (withoutSize, size) = splitSize(trimmed)
            var path = withoutSize
            while path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty else { return nil }
            return PathListLine(lineNumber: index + 1, text: trimmed, path: path, listedSize: size)
        }
    }

    /// Matches the list against tracked files. `rootNames` are extra folder names that may
    /// prefix every path (e.g. the destination folder's name); the share root's name is
    /// derived from the entries.
    public static func select(_ text: String, from entries: [FileEntry],
                              rootNames: Set<String> = []) -> PathListSelection {
        let index = Dictionary(entries.map { (key($0.record.relPath), $0) }, uniquingKeysWith: { first, _ in first })
        let topLevel = Set(entries.compactMap { key($0.record.relPath).split(separator: "/").first.map(String.init) })
        let prefixes = Set((rootNames.union(entries.compactMap(shareRootName))).map(key)).subtracting(topLevel)
        var seen: Set<String> = []
        var matched: [FileEntry] = []
        var unmatched: [String] = []
        var differences: [PathListSizeDifference] = []
        for line in parse(text) {
            guard let entry = lookup(line.path, index: index, prefixes: prefixes) else {
                unmatched.append(line.text)
                continue
            }
            guard seen.insert(entry.record.path).inserted else { continue }
            matched.append(entry)
            if let listed = line.listedSize, listed != entry.record.size {
                differences.append(PathListSizeDifference(relPath: entry.record.relPath, listed: listed,
                                                          recorded: entry.record.size))
            }
        }
        return PathListSelection(matched: matched, unmatched: unmatched, sizeDifferences: differences)
    }

    private static func lookup(_ path: String, index: [String: FileEntry], prefixes: Set<String>) -> FileEntry? {
        let wanted = key(path)
        if let entry = index[wanted] { return entry }
        let parts = wanted.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, prefixes.contains(String(parts[0])) else { return nil }
        return index[String(parts[1])]
    }

    private static func splitSize(_ line: String) -> (String, Int64?) {
        let range = NSRange(line.startIndex..., in: line)
        guard let regex = sizeAnnotation, let match = regex.firstMatch(in: line, range: range),
              let whole = Range(match.range, in: line), let digits = Range(match.range(at: 1), in: line) else {
            return (line, nil)
        }
        let size = Int64(line[digits].replacingOccurrences(of: ",", with: ""))
        return (String(line[..<whole.lowerBound]), size)
    }

    /// The share root folder's name: the remote path minus `/rel_path`.
    private static func shareRootName(_ entry: FileEntry) -> String? {
        let record = entry.record
        guard record.path.count > record.relPath.count + 1 else { return nil }
        let root = String(record.path.dropLast(record.relPath.count + 1))
        let name = (root as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    private static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
