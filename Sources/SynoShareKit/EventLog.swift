import Darwin
import Foundation

/// Append-only log at `<dest>/.synoshare/log.txt`.
///
/// Every line passes through `redact`, which replaces the share link id (and server
/// id) so the log can be shared for support. The password never reaches this type.
public final class EventLog: @unchecked Sendable {
    public static let fileName = "log.txt"
    static let placeholder = "<redacted>"

    private let url: URL
    private let secrets: [String]
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public init(directory: URL, secrets: [String]) {
        url = directory.appending(path: Self.fileName)
        self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public static func redact(_ text: String, secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: placeholder) }
    }

    /// Best effort: a log failure (e.g. the drive just vanished) must not stop a download.
    public func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(Self.redact(message, secrets: secrets))\n"
        lock.withLock {
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, SafeFS.fileMode)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            try? SafeFS.write(Data(line.utf8), to: descriptor, path: url.path)
        }
    }
}
