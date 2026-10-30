import Darwin
import Foundation

/// Reads the share password from the terminal with echo off. `RPP_REQUIRE_TTY`
/// refuses to read from a pipe or file, so the password can only be typed.
func readPassword(prompt: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { for index in buffer.indices { buffer[index] = 0 } }
    guard let result = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else { return nil }
    return String(cString: result)
}

func fail(_ message: String) -> Never {
    printError("error: \(message)")
    exit(1)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func formatBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
    return hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))m" : "\(minutes)m\(String(format: "%02d", secs))s"
}

/// First Ctrl-C asks for a graceful stop (finish the current chunk, flush state);
/// a second one exits immediately.
final class InterruptHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceSignal?
    private var count = 0

    func install(onFirst: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let presses = self.lock.withLock { () -> Int in
                self.count += 1
                return self.count
            }
            if presses > 1 { exit(130) }
            printError("\nStopping after the current chunks (press Ctrl-C again to quit immediately)...")
            onFirst()
        }
        source.resume()
        lock.withLock { self.source = source }
    }
}
