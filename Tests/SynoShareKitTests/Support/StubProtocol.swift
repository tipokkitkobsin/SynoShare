import Foundation
import XCTest
@testable import SynoShareKit

/// Routes every request of a stub session to the current `FakeNAS`. No real network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: FakeNAS?
    static let chunkSize = 16 * 1024

    static var nas: FakeNAS? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.nas?.handle(request) ?? StubReply(error: URLError(.cannotConnectToHost))
        guard let client else { return }
        if let error = reply.error {
            client.urlProtocol(self, didFailWithError: error)
            return
        }
        var headers = reply.headers
        if headers["Content-Length"] == nil, reply.dropAfter == nil { headers["Content-Length"] = String(reply.body.count) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: headers) else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let limit = min(reply.dropAfter ?? reply.body.count, reply.body.count)
        var offset = 0
        while offset < limit {
            let end = min(offset + Self.chunkSize, limit)
            client.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        if reply.dropAfter != nil {
            // Let the delivered chunks reach the delegate before the connection "drops",
            // as on a real network where bytes arrive well before the reset.
            Thread.sleep(forTimeInterval: 0.05)
            client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Shared fixtures for engine tests.
class EngineTestCase: XCTestCase {
    var nas: FakeNAS!
    var destination: URL!

    override func setUpWithError() throws {
        nas = FakeNAS()
        StubProtocol.nas = nas
        destination = FileManager.default.temporaryDirectory
            .appending(path: "synoshare-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.nas = nil
        try? FileManager.default.removeItem(at: destination)
    }

    static let linkID = "LinkSecret42"

    func makeEngine(password: String = "secret",
                    configure: (inout EngineConfiguration) -> Void = { _ in }) throws -> DownloadEngine {
        var configuration = EngineConfiguration(link: try ShareLink(serverID: "Srv1", linkID: Self.linkID),
                                                destination: destination)
        configuration.preventSleep = false
        configuration.retryPolicy = RetryPolicy(baseDelay: 0.001, maxDelay: 0.004, maxAttempts: 4)
        configuration.tickInterval = .milliseconds(20)
        configuration.makeSession = { StubProtocol.makeSession() }
        configuration.resolveEndpoint = { _, _ in
            ShareEndpoint(baseURL: URL(string: "https://nas.test")!, relayRegion: "test", controlHost: "control.test")
        }
        configure(&configuration)
        return try DownloadEngine(configuration: configuration, passwordProvider: { password })
    }

    func local(_ relative: String) -> URL { destination.appending(path: relative) }

    func contents(_ relative: String) -> Data? { try? Data(contentsOf: local(relative)) }

    func store() throws -> StateStore { try StateStore.open(destination: destination, create: false) }

    static func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }
}
