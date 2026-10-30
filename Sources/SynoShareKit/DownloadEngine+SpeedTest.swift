import Foundation

extension DownloadEngine {
    public static let defaultSpeedTestBytes: Int64 = 32 * 1024 * 1024

    /// Range-fetches the first `byteCount` bytes of the largest listed file (lists first
    /// if nothing is known yet) and measures throughput. Nothing is written to disk.
    public func speedTest(byteCount: Int64 = DownloadEngine.defaultSpeedTestBytes) async throws -> SpeedTestResult {
        try beginRun()
        defer { endRun() }
        let client = try await connectedClient()
        if try store.largestFile() == nil { try await listShare(refresh: false) }
        guard let largest = try store.largestFile(), largest.size > 0 else {
            throw SynoError.unexpectedResponse("speed test (no non-empty file listed)")
        }
        let count = min(max(byteCount, 1), largest.size)
        let request = try await client.downloadRequest(remotePath: largest.path, range: "0-\(count - 1)")
        let counter = ByteCounter()
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await StreamingFetch.run(request, session: session, decide: { response in
            (response.statusCode == 200 || response.statusCode == 206)
                && !Downloader.isPossibleErrorReply(response, remaining: count)
        }, sink: { data in
            counter.add(Int64(data.count)) < count
        })
        let elapsed = clock.now - started
        if let code = ShareClient.errorCode(in: result.body) { throw SynoError.api(code: code, context: "speed test") }
        guard (200..<300).contains(result.response.statusCode) else {
            throw SynoError.http(status: result.response.statusCode, context: "speed test")
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let bytes = min(counter.value, count)
        note("speed test: \(bytes) bytes in \(seconds) s")
        return SpeedTestResult(bytes: bytes, seconds: seconds)
    }
}

/// Thread-safe running total for the speed test sink.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    var value: Int64 { lock.withLock { total } }

    /// Adds and returns the new total.
    func add(_ count: Int64) -> Int64 {
        lock.withLock {
            total += count
            return total
        }
    }
}
