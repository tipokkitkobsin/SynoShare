import Foundation

let usage = """
usage:
  synoshare probe        <share-url> --dest <folder>
  synoshare list         <share-url> --dest <folder>
  synoshare download     <share-url> --dest <folder> [--concurrency N] [--allow-sleep]
  synoshare retry-failed <share-url> --dest <folder> [--concurrency N] [--allow-sleep]
  synoshare speedtest    <share-url> --dest <folder> [--mib N]
  synoshare status       --dest <folder>
  synoshare verify       --dest <folder>
  synoshare resolve      --dest <folder> <remote-path> replace|keep-both

The share password is asked interactively (hidden). It is never read from
arguments, environment or files, and never printed or stored.
Ctrl-C stops gracefully; run the same command again to resume.
`download` continues an interrupted listing; `list` re-scans the whole share
for new files and files changed on the server.
"""

/// Parsed command line. Options take one value; flags take none.
struct Arguments {
    static let valueOptions: Set<String> = ["--dest", "--concurrency", "--mib"]
    static let flagOptions: Set<String> = ["--allow-sleep"]

    let command: String
    let positionals: [String]
    let options: [String: String]
    let flags: Set<String>

    init(_ raw: [String]) throws {
        guard let command = raw.first else { throw ArgumentError(usage) }
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        while index < raw.count {
            let item = raw[index]
            if Self.valueOptions.contains(item) {
                guard index + 1 < raw.count else { throw ArgumentError("\(item) needs a value") }
                options[item] = raw[index + 1]
                index += 2
            } else if Self.flagOptions.contains(item) {
                flags.insert(item)
                index += 1
            } else if item.hasPrefix("--") {
                throw ArgumentError("unknown option \(item)")
            } else {
                positionals.append(item)
                index += 1
            }
        }
        self.command = command
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    /// The existing destination folder.
    func destination() throws -> URL {
        guard let path = options["--dest"] else { throw ArgumentError("--dest <folder> is required") }
        let url = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArgumentError("destination folder does not exist: \(url.path)")
        }
        return url
    }

    func positiveInt(_ option: String, default value: Int) throws -> Int {
        guard let text = options[option] else { return value }
        guard let number = Int(text), number > 0 else { throw ArgumentError("\(option) must be a positive number") }
        return number
    }

    func requirePositionals(_ count: Int) throws {
        guard positionals.count == count else { throw ArgumentError(usage) }
    }
}

struct ArgumentError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
