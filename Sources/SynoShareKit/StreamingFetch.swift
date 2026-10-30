import Foundation

/// Result of a streamed request. `body` holds the collected bytes when the
/// response was not streamed (error pages, JSON error replies).
struct FetchResult: Sendable {
    let response: HTTPURLResponse
    let body: Data
    /// The sink asked to stop before the server finished (used by the speed test).
    let stoppedEarly: Bool
}

/// One streaming GET driven by `URLSessionDataDelegate`: chunks go straight to
/// `sink` as they arrive, so memory stays flat for an 81 GiB file.
///
/// Delegate callbacks for one session run on its serial delegate queue, so a chunk
/// write always completes before `didCompleteWithError` – cancelling mid-transfer
/// therefore leaves the `.part` consistent ("finish current chunk write").
final class StreamingFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Called once with the response headers. Return true to stream the body to `sink`,
    /// false to collect it in memory (bounded). Throwing aborts the request.
    typealias Decide = @Sendable (HTTPURLResponse) throws -> Bool
    /// Called for each chunk. Return false to stop early.
    typealias Sink = @Sendable (Data) throws -> Bool

    static let collectLimit = 1 << 20

    private let decide: Decide
    private let sink: Sink
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var response: HTTPURLResponse?
    private var streaming = false
    private var collected = Data()
    private var abortError: Error?
    private var stoppedEarly = false

    private init(decide: @escaping Decide, sink: @escaping Sink) {
        self.decide = decide
        self.sink = sink
    }

    static func run(_ request: URLRequest, session: URLSession,
                    decide: @escaping Decide, sink: @escaping Sink) async throws -> FetchResult {
        try Task.checkCancellation()
        let fetch = StreamingFetch(decide: decide, sink: sink)
        let task = session.dataTask(with: request)
        task.delegate = fetch
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fetch.withLock { fetch.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            withLock { abortError = DownloadError.transient("Not an HTTP response.") }
            completionHandler(.cancel)
            return
        }
        do {
            let shouldStream = try decide(http)
            withLock {
                self.response = http
                streaming = shouldStream
            }
            completionHandler(.allow)
        } catch {
            withLock {
                self.response = http
                abortError = error
            }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (isStreaming, isAborted) = withLock { (streaming, abortError != nil || stoppedEarly) }
        guard !isAborted else { return }
        guard isStreaming else {
            withLock {
                if collected.count < Self.collectLimit { collected.append(data.prefix(Self.collectLimit - collected.count)) }
            }
            return
        }
        do {
            if try !sink(data) {
                withLock { stoppedEarly = true }
                dataTask.cancel()
            }
        } catch {
            withLock { abortError = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome) = withLock { () -> (CheckedContinuation<FetchResult, Error>?, Result<FetchResult, Error>) in
            let pending = self.continuation
            self.continuation = nil
            return (pending, outcome(error: error))
        }
        continuation?.resume(with: outcome)
    }

    /// Must be called with the lock held.
    private func outcome(error: Error?) -> Result<FetchResult, Error> {
        if let abortError { return .failure(abortError) }
        if let response, stoppedEarly || error == nil {
            return .success(FetchResult(response: response, body: collected, stoppedEarly: stoppedEarly))
        }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .failure(CancellationError()) }
        return .failure(error ?? DownloadError.transient("No response."))
    }
}
