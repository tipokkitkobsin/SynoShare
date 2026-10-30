import Darwin
import Foundation

/// Appends downloaded chunks to a `.part` file and reports byte deltas.
/// Opened with `O_NOFOLLOW`, so it never writes through a symlink.
final class PartWriter: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var descriptor: Int32
    private var written: Int64
    private let report: @Sendable (Int64) -> Void

    init(url: URL, offset: Int64, report: @escaping @Sendable (Int64) -> Void) throws {
        self.url = url
        self.report = report
        descriptor = try SafeFS.openForWriting(url, at: offset)
        written = offset
    }

    deinit { close() }

    var position: Int64 { lock.withLock { written } }

    func append(_ data: Data) throws {
        try lock.withLock {
            try SafeFS.write(data, to: descriptor, path: url.path)
            written += Int64(data.count)
        }
        report(Int64(data.count))
    }

    /// Discards everything after `offset` (e.g. the server ignored our Range and restarts at 0).
    func truncate(to offset: Int64) throws {
        let delta: Int64 = try lock.withLock {
            guard ftruncate(descriptor, off_t(offset)) == 0, lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else {
                throw LocalFileError(code: errno, operation: "truncate", path: url.path)
            }
            let delta = offset - written
            written = offset
            return delta
        }
        report(delta)
    }

    /// Flushes to the physical drive and closes.
    func finish() throws {
        try lock.withLock {
            try SafeFS.fullSync(descriptor, path: url.path)
        }
        close()
    }

    func close() {
        lock.withLock {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
        }
    }
}

/// `Content-Range: bytes <start>-<end>/<total|*>`.
struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64?

    init?(_ header: String?) {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst("bytes ".count)
        let halves = spec.split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start <= end else { return nil }
        self.start = start
        self.end = end
        total = halves[1] == "*" ? nil : Int64(halves[1])
    }
}
