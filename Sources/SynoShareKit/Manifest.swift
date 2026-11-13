import Foundation

/// One line of a checksum manifest: a path relative to the share root and its hash.
public struct ManifestEntry: Sendable, Equatable {
    public let path: String
    public let expected: ExpectedHash

    public init(path: String, expected: ExpectedHash) {
        self.path = path
        self.expected = expected
    }
}

public struct ManifestParseResult: Sendable, Equatable {
    public let entries: [ManifestEntry]
    /// 1-based numbers of lines that are neither entries, blank, nor `#` comments.
    public let invalidLines: [Int]
}

/// What importing a manifest did to the state DB.
public struct ManifestImportResult: Sendable, Equatable {
    /// Entries whose path matched a tracked file.
    public let matched: Int
    /// Entry paths no tracked file has (reported, not fatal).
    public let unknownPaths: [String]
    public let invalidLines: Int
    /// Matched files whose recorded SHA-256 already disagrees with the manifest.
    public let mismatched: Int
}

/// `sha256sum` / `md5sum` output: `<hex>  <path>` (text mode) or `<hex> *<path>` (binary).
/// 64 hex digits = SHA-256, 32 = MD5. Lines escaped by GNU coreutils (leading `\`) are unescaped.
public enum Manifest {
    public static func parse(_ text: String) -> ManifestParseResult {
        var entries: [ManifestEntry] = []
        var invalid: [Int] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let entry = entry(from: String(line)) else {
                invalid.append(index + 1)
                continue
            }
            entries.append(entry)
        }
        return ManifestParseResult(entries: entries, invalidLines: invalid)
    }

    static func entry(from line: String) -> ManifestEntry? {
        let escaped = line.hasPrefix("\\")
        let body = escaped ? String(line.dropFirst()) : line
        guard let space = body.firstIndex(of: " ") else { return nil }
        let hex = body[..<space].lowercased()
        guard let algorithm = HashAlgorithm(hexLength: hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        var rawPath = body[body.index(after: space)...]
        if rawPath.first == " " || rawPath.first == "*" { rawPath = rawPath.dropFirst() }
        let path = normalised(escaped ? unescape(String(rawPath)) : String(rawPath))
        guard !path.isEmpty else { return nil }
        return ManifestEntry(path: path, expected: ExpectedHash(algorithm: algorithm, hex: hex))
    }

    /// Paths are relative to the share root; `./` (as `find .` prints) is tolerated.
    static func normalised(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    /// GNU coreutils escaping: `\\` → `\`, `\n` → newline, `\r` → carriage return.
    static func unescape(_ text: String) -> String {
        var result = ""
        var pendingBackslash = false
        for character in text {
            guard pendingBackslash else {
                if character == "\\" { pendingBackslash = true } else { result.append(character) }
                continue
            }
            pendingBackslash = false
            switch character {
            case "n": result.append("\n")
            case "r": result.append("\r")
            default: result.append(character)
            }
        }
        return result
    }
}

extension StateStore {
    /// Stores each entry's hash as the file's expected hash (matched by `rel_path`).
    /// A new MD5 reference clears `hashed_at` (the file needs Deep Verify to be compared).
    func importManifest(_ parsed: ManifestParseResult) throws -> ManifestImportResult {
        try db.transaction {
            var matched: [String] = []
            var unknown: [String] = []
            for entry in parsed.entries {
                guard let record = try file(relPath: entry.path) else {
                    unknown.append(entry.path)
                    continue
                }
                try setExpectedHash(record, entry.expected)
                matched.append(record.path)
            }
            let mismatched = try matched.compactMap { try file($0) }
                .filter { FileHealth($0) == .checksumMismatch }.count
            return ManifestImportResult(matched: matched.count, unknownPaths: unknown,
                                        invalidLines: parsed.invalidLines.count, mismatched: mismatched)
        }
    }

    func file(relPath: String) throws -> FileRecord? {
        try db.query("SELECT * FROM file WHERE rel_path = ? AND status != 'skipped_unsafe' LIMIT 1",
                     [.text(relPath)]).first.map(FileRecord.init(row:))
    }

    private func setExpectedHash(_ record: FileRecord, _ expected: ExpectedHash) throws {
        let needsRehash = expected.algorithm == .md5 && record.expectedHash != expected
        try db.query("""
            UPDATE file SET expected_hash = ?, expected_algo = ?,
                hashed_at = CASE WHEN ? THEN NULL ELSE hashed_at END WHERE path = ?
            """, [.text(expected.hex), .text(expected.algorithm.rawValue),
                  .integer(needsRehash ? 1 : 0), .text(record.path)])
    }
}
