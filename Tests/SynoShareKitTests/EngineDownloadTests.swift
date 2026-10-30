import XCTest
@testable import SynoShareKit

/// End-to-end engine runs against the in-memory NAS: happy path, resume and HTTP edge cases.
final class EngineDownloadTests: EngineTestCase {
    func testDownloadsWholeTreeWithMtimeAndReport() async throws {
        let big = Self.bytes(100_000)
        nas.addFile("/Share/a.txt", Data("hello".utf8), mtime: 1_600_000_000)
        nas.addFile("/Share/sub/deep/big.bin", big)
        nas.addFile("/Share/empty.dat", Data())
        nas.addFolder("/Share/emptyfolder")
        let engine = try makeEngine()

        let report = try await engine.run()

        XCTAssertEqual(contents("a.txt"), Data("hello".utf8))
        XCTAssertEqual(contents("sub/deep/big.bin"), big)
        XCTAssertEqual(contents("empty.dat"), Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: local("emptyfolder").path))
        let modified = try FileManager.default.attributesOfItem(atPath: local("a.txt").path)[.modificationDate] as? Date
        XCTAssertEqual(modified, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(report.count(.done), 3)
        XCTAssertEqual(report.files, 3)
        XCTAssertEqual(report.expectedBytes, Int64(big.count + 5))
        XCTAssertEqual(report.completedBytes, report.expectedBytes)
        XCTAssertTrue(report.listingComplete)
        XCTAssertTrue(report.text.contains("not an integrity guarantee"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("a.txt.synoshare.part").path))
        await engine.shutdown()
    }

    func testResumesFromPartWithRangeRequest() async throws {
        let data = Self.bytes(50_000)
        nas.addFile("/Share/movie.mkv", data)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.prefix(20_000).write(to: local("movie.mkv.synoshare.part"))
        let engine = try makeEngine()

        _ = try await engine.run()

        XCTAssertEqual(contents("movie.mkv"), data)
        XCTAssertEqual(nas.rangesRequested("/Share/movie.mkv"), ["bytes=20000-"])
    }

    func testServerIgnoringRangeRestartsFromZero() async throws {
        let data = Self.bytes(40_000)
        nas.addFile("/Share/f.bin", data)
        nas.script("/Share/f.bin", [.ignoreRange])
        try Data(repeating: 0xFF, count: 10_000).write(to: local("f.bin.synoshare.part"))
        let engine = try makeEngine()

        _ = try await engine.run()

        XCTAssertEqual(contents("f.bin"), data)
    }

    func testRangeNotSatisfiableRestartsFile() async throws {
        let data = Self.bytes(30_000)
        nas.addFile("/Share/f.bin", data)
        nas.script("/Share/f.bin", [.rangeNotSatisfiable])
        try data.prefix(5_000).write(to: local("f.bin.synoshare.part"))
        let engine = try makeEngine()

        _ = try await engine.run()

        XCTAssertEqual(contents("f.bin"), data)
        XCTAssertEqual(nas.rangesRequested("/Share/f.bin"), ["bytes=5000-", nil])
    }

    func testInterruptedTransferResumesWhereItStopped() async throws {
        let data = Self.bytes(80_000)
        nas.addFile("/Share/f.bin", data)
        nas.script("/Share/f.bin", [.dropAfter(32_768)])
        let engine = try makeEngine()

        _ = try await engine.run()

        XCTAssertEqual(contents("f.bin"), data)
        XCTAssertEqual(nas.rangesRequested("/Share/f.bin"), [nil, "bytes=32768-"])
        XCTAssertEqual(try store().file("/Share/f.bin")?.attempts, 1)
    }

    func testRetriesThrottlingAndTimeoutsThenSucceeds() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(1000))
        nas.script("/Share/f.bin", [.status(503), .timeout, .status(429)])
        let engine = try makeEngine()

        let report = try await engine.run()

        XCTAssertEqual(report.count(.done), 1)
        XCTAssertEqual(try store().file("/Share/f.bin")?.attempts, 3)
        let concurrency = await engine.concurrency.current
        XCTAssertEqual(concurrency, 1, "three throttling signals drop concurrency to 1")
    }

    func testPersistentServerErrorFailsThenRetryFailedSucceeds() async throws {
        let data = Self.bytes(2000)
        nas.addFile("/Share/f.bin", data)
        nas.script("/Share/f.bin", Array(repeating: .status(500), count: 4))
        let engine = try makeEngine()

        let first = try await engine.run()
        XCTAssertEqual(first.count(.failed), 1)
        XCTAssertEqual(first.failed.first?.relPath, "f.bin")
        XCTAssertNil(contents("f.bin"))

        let second = try await engine.retryFailed()
        XCTAssertEqual(second.count(.done), 1)
        XCTAssertEqual(contents("f.bin"), data)
    }

    func testSessionExpiryLogsInAgainAndContinues() async throws {
        let data = Self.bytes(3000)
        nas.addFile("/Share/f.bin", data)
        nas.script("/Share/f.bin", [.sessionExpired])
        let engine = try makeEngine()

        _ = try await engine.run()

        XCTAssertEqual(contents("f.bin"), data)
        XCTAssertEqual(nas.logins, 2)
    }

    func testSessionExpiryDuringListingLogsInAgain() async throws {
        nas.addFile("/Share/x/f.txt", Data("x".utf8))
        let engine = try makeEngine()
        try await engine.connect()
        nas.expireSession()

        let report = try await engine.list()

        XCTAssertEqual(report.files, 1)
        XCTAssertEqual(nas.logins, 2)
    }

    func testWrongPasswordStopsWithError() async throws {
        nas.addFile("/Share/f.bin", Data("x".utf8))
        let engine = try makeEngine(password: "nope")

        do {
            _ = try await engine.run()
            XCTFail("expected wrong password")
        } catch {
            XCTAssertEqual(error as? SynoError, .wrongPassword)
        }
    }

    func testFileSizeChangedDuringResumeRefreshesListing() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(10_000))
        let engine = try makeEngine()
        _ = try await engine.list()
        let newer = Self.bytes(12_000, seed: 3)
        nas.addFile("/Share/f.bin", newer, mtime: 1_700_000_500)
        try Self.bytes(4_000).write(to: local("f.bin.synoshare.part"))

        _ = try await engine.run()

        XCTAssertEqual(contents("f.bin"), newer)
        XCTAssertEqual(try store().file("/Share/f.bin")?.size, 12_000)
    }

    func testLogIsRedactedAndHasNoPassword() async throws {
        nas.addFile("/Share/f.bin", Data("x".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()
        let log = try String(contentsOf: StateStore.stateDirectory(for: destination).appending(path: "log.txt"),
                             encoding: .utf8)
        XCTAssertFalse(log.isEmpty)
        XCTAssertFalse(log.contains(Self.linkID))
        XCTAssertFalse(log.contains("secret"))
        let databaseText = String(decoding: try Data(contentsOf: StateStore.stateDirectory(for: destination)
            .appending(path: StateStore.databaseName)), as: UTF8.self)
        XCTAssertFalse(databaseText.contains("secret"))
    }

    func testEventsReportProgressAndPhases() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(5000))
        let engine = try makeEngine()
        let collector = Task { () -> [EngineEvent] in
            var events: [EngineEvent] = []
            for await event in engine.events { events.append(event) }
            return events
        }
        _ = try await engine.run()
        await engine.shutdown()
        let events = await collector.value

        XCTAssertTrue(events.contains(.phase(.downloading)))
        XCTAssertTrue(events.contains(.fileFinished(path: "/Share/f.bin", status: .done)))
        let last = events.compactMap { event -> ProgressSnapshot? in
            if case .progress(let snapshot) = event { return snapshot }
            return nil
        }.last
        XCTAssertEqual(last?.completedBytes, 5000)
        XCTAssertEqual(last?.fractionCompleted, 1)
    }

    func testSpeedTestFetchesRequestedBytes() async throws {
        nas.addFile("/Share/small.bin", Self.bytes(10))
        nas.addFile("/Share/large.bin", Self.bytes(300_000))
        let engine = try makeEngine()

        let result = try await engine.speedTest(byteCount: 100_000)

        XCTAssertEqual(result.bytes, 100_000)
        XCTAssertEqual(nas.rangesRequested("/Share/large.bin"), ["bytes=0-99999"])
        XCTAssertGreaterThanOrEqual(result.megabytesPerSecond, 0)
        XCTAssertNil(contents("large.bin"), "speed test writes nothing")
    }
}
