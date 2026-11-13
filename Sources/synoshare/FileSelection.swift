import Foundation
import SynoShareKit

/// Which files `files` and `repair` act on: a health/glob filter, a path list, or both (union).
struct FileSelection: Equatable {
    /// Nil when no filter option was given.
    let filter: FileFilter?
    /// `--paths-from` value; `-` is standard input.
    let pathsFile: String?

    /// The selected entries in listing order. With neither a filter nor a list, everything.
    func apply(all: [FileEntry], filtered: [FileEntry], listText: String?,
               rootNames: Set<String>) -> (entries: [FileEntry], list: PathListSelection?) {
        let list = listText.map { PathList.select($0, from: all, rootNames: rootNames) }
        guard filter != nil || list != nil else { return (all, nil) }
        let wanted = Set((filter == nil ? [] : filtered.map(\.record.path)) + (list?.paths ?? []))
        return (all.filter { wanted.contains($0.record.path) }, list)
    }
}

extension Arguments {
    /// `--health`, `--broken` and `--match` as a filter. No options match everything.
    func fileFilter() throws -> FileFilter {
        var health = try options["--health"].map(Self.parseHealth) ?? []
        if flags.contains("--broken") { health.formUnion(FileHealth.broken) }
        let glob = try options["--match"].map(Self.validGlob)
        return FileFilter(health: health, glob: glob)
    }

    /// The filter (if any filter option was given) and the path list file.
    func selection(requireAny: Bool) throws -> FileSelection {
        let hasFilter = options["--health"] != nil || options["--match"] != nil || flags.contains("--broken")
        let pathsFile = options["--paths-from"]
        if requireAny, !hasFilter, pathsFile == nil {
            throw ArgumentError("choose files with --broken, --match <glob> or --paths-from <file>")
        }
        return FileSelection(filter: hasFilter ? try fileFilter() : nil, pathsFile: pathsFile)
    }

    private static func parseHealth(_ list: String) throws -> Set<FileHealth> {
        var result: Set<FileHealth> = []
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            guard let health = FileHealth(cliName: name) else {
                let valid = FileHealth.allCases.map(\.cliName).joined(separator: ", ")
                throw ArgumentError("unknown health \(name); use one of: \(valid)")
            }
            result.insert(health)
        }
        return result
    }

    private static func validGlob(_ text: String) throws -> String {
        let pattern = text.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { throw ArgumentError("--match needs a non-empty glob") }
        do {
            _ = try Glob(pattern)
        } catch {
            throw ArgumentError("invalid --match glob \(pattern): \(error.localizedDescription)")
        }
        return pattern
    }
}

/// Reads a `--paths-from` file, or standard input for `-`.
func readPathList(_ file: String) throws -> String {
    let data: Data
    if file == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        let url = URL(filePath: (file as NSString).expandingTildeInPath)
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ArgumentError("cannot read path list \(url.path): \(error.localizedDescription)")
        }
    }
    guard let text = String(data: data, encoding: .utf8) else { throw ArgumentError("path list is not UTF-8 text") }
    return text
}
