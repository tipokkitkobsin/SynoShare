import Foundation

/// A listed entry with the local path it will be written to.
/// `localPath` is nil when the remote name is unsafe and the entry is skipped.
public struct MappedEntry: Sendable, Equatable {
    public let entry: ShareEntry
    public let relPath: String
    public let localPath: String?
    /// True when a case-insensitive collision forced a `name (2)` rename.
    public let renamed: Bool
}

/// Maps remote names to local paths under the destination.
///
/// The destination is exFAT: case-insensitive and Unicode-normalisation-insensitive,
/// so two remote names that differ only in case would land on the same file.
/// The later one (in name order) is renamed `name (2).ext` (DECISIONS #8).
public enum PathMapper {
    /// Names reserved at the destination root (the engine's own state folder).
    static let reservedRootKeys: Set<String> = [collisionKey(StateStore.directoryName)]

    /// A remote name is safe when it is one path component that cannot escape the destination.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        return !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// The key two names collide on when the filesystem is case-insensitive.
    public static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `report.pdf` → `report (2).pdf`; `.profile` → `.profile (2)`; `Folder` → `Folder (2)`.
    public static func numbered(_ name: String, _ number: Int) -> String {
        let dot = name.lastIndex(of: ".")
        guard let dot, dot != name.startIndex else { return "\(name) (\(number))" }
        return "\(name[..<dot]) (\(number))\(name[dot...])"
    }

    /// The first `name (n)` (n ≥ 2) whose key is not in `taken`; `name` itself if free.
    public static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(collisionKey(name)) else { return name }
        var number = 2
        while taken.contains(collisionKey(numbered(name, number))) { number += 1 }
        return numbered(name, number)
    }

    public static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    /// Plans local paths for one listed folder.
    ///
    /// - Parameters:
    ///   - folderPath: remote path of the folder that was listed.
    ///   - parentRel / parentLocal: that folder's path relative to the root, remotely and locally.
    ///   - existing: remote path → local path for children already tracked (kept stable on relist).
    public static func mapChildren(of folderPath: String, parentRel: String, parentLocal: String,
                                   entries: [ShareEntry], existing: [String: String]) -> [MappedEntry] {
        var taken = Set(existing.values.map { collisionKey(lastComponent($0)) })
        if parentLocal.isEmpty { taken.formUnion(reservedRootKeys) }
        let sorted = entries.sorted { $0.name < $1.name }
        return sorted.map { entry in
            let relPath = join(parentRel, entry.name)
            let isConsistent = entry.path == folderPath + "/" + entry.name
            guard isSafeName(entry.name), isConsistent else {
                return MappedEntry(entry: entry, relPath: relPath, localPath: nil, renamed: false)
            }
            if let known = existing[entry.path] {
                return MappedEntry(entry: entry, relPath: relPath, localPath: known,
                                   renamed: lastComponent(known) != entry.name)
            }
            let name = uniqueName(entry.name, taken: taken)
            taken.insert(collisionKey(name))
            return MappedEntry(entry: entry, relPath: relPath, localPath: join(parentLocal, name),
                               renamed: name != entry.name)
        }
    }

    /// The URL of a destination-relative path. Callers only pass paths built from safe names.
    public static func localURL(destination: URL, relative: String) -> URL {
        relative.isEmpty ? destination : destination.appending(path: relative)
    }

    /// The in-progress sibling of a local file. A distinctive suffix keeps it from
    /// colliding with a real remote file that happens to end in `.part`.
    public static func partURL(for local: URL) -> URL {
        local.deletingLastPathComponent().appending(path: local.lastPathComponent + ".synoshare.part")
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
