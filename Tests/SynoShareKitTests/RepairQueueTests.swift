import XCTest
@testable import SynoShareKit

/// The repair queue: selected files stay queued until they are repaired, across
/// stop, failure and a new process, and Download All never touches them.
final class RepairQueueTests: EngineTestCase {
    /// Downloads `f.bin`, then breaks its local copy (size mismatch).
    private func makeBrokenFile(_ data: Data) async throws -> DownloadEngine {
        nas.addFile("/Share/f.bin", data)
        let engine = try makeEngine()
        _ = try await engine.run()
        try Data("broken".utf8).write(to: local("f.bin"))
        _ = try await engine.verify()
        return engine
    }

    /// A repair that fails on every attempt: the file stays queued.
    private func queueByFailedRepair(_ engine: DownloadEngine, _ path: String) async throws {
        nas.script(path, Array(repeating: .status(500), count: 10))
        _ = try await engine.repair(paths: [path])
        nas.script(path, [])
    }

    private func queued() throws -> [String] {
        try DownloadEngine.queuedRepairs(destination: destination).map(\.record.relPath)
    }

    func testStoppedRepairStaysQueuedAndResumesFromPartInNewEngine() async throws {
        let data = Self.bytes(50_000)
        _ = try await makeBrokenFile(data)
        nas.script("/Share/f.bin", Array(repeating: .timeout, count: 3))
        let engine = try makeEngine { $0.retryPolicy = RetryPolicy(baseDelay: 0.5, maxDelay: 0.5, maxAttempts: 8) }
        let repair = Task { try await engine.repair(paths: ["/Share/f.bin"]) }
        for await event in engine.events {
            if case .fileRetrying = event { break }
        }
        await engine.stop()
        let stopped = try await repair.value

        XCTAssertEqual(stopped.stillBroken.map(\.relPath), ["f.bin"])
        XCTAssertEqual(try queued(), ["f.bin"])
        XCTAssertEqual(try store().file("/Share/f.bin")?.replaceExisting, false)
        XCTAssertEqual(contents("f.bin"), Data("broken".utf8), "the old copy stays until the repair passes")

        try data.prefix(20_000).write(to: local("f.bin.synoshare.part"))
        XCTAssertEqual(try DownloadEngine.queuedRepairPartBytes(destination: destination), 20_000)
        nas.script("/Share/f.bin", [])
        let resumed = try makeEngine()
        let summary = try await resumed.resumeRepair()

        XCTAssertEqual(summary.repaired, ["f.bin"])
        XCTAssertEqual(nas.rangesRequested("/Share/f.bin").last, "bytes=20000-")
        XCTAssertEqual(contents("f.bin"), data)
        XCTAssertEqual(try queued(), [])
        XCTAssertEqual(try store().file("/Share/f.bin")?.repairQueued, false)
    }

    func testSuccessfulRepairEmptiesQueue() async throws {
        let engine = try await makeBrokenFile(Self.bytes(4000))

        _ = try await engine.repair(paths: ["/Share/f.bin"])

        let queue = try await engine.queuedRepairs()
        XCTAssertEqual(queue, [])
    }

    func testFailedRepairStaysQueued() async throws {
        let engine = try await makeBrokenFile(Self.bytes(4000))

        try await queueByFailedRepair(engine, "/Share/f.bin")

        let queue = try await engine.queuedRepairs()
        XCTAssertEqual(queue.map(\.record.relPath), ["f.bin"])
        XCTAssertEqual(try store().file("/Share/f.bin")?.replaceExisting, false)
    }

    func testChecksumRejectStaysQueued() async throws {
        let engine = try await makeBrokenFile(Self.bytes(4000))
        _ = try await engine.importManifest("\(Self.sha256(Self.bytes(4000, seed: 9)))  f.bin")

        let summary = try await engine.repair(paths: ["/Share/f.bin"])

        XCTAssertEqual(summary.repaired, [])
        XCTAssertEqual(try queued(), ["f.bin"])
    }

    func testUnsafeAndUnknownPathsAreNotQueued() async throws {
        nas.addRawEntry(in: "/Share", name: "bad\u{7}name")
        let engine = try makeEngine()
        _ = try await engine.run()

        _ = try await engine.repair(paths: ["/Share/nope.txt", "/Share/bad\u{7}name"])

        XCTAssertEqual(try queued(), [])
    }

    func testResumeRepairsOnlyQueuedFiles() async throws {
        nas.addFile("/Share/a.bin", Self.bytes(4000))
        nas.addFile("/Share/b.bin", Self.bytes(4000, seed: 2))
        let engine = try makeEngine()
        _ = try await engine.run()
        try Data("bad".utf8).write(to: local("a.bin"))
        try Data("bad".utf8).write(to: local("b.bin"))
        _ = try await engine.verify()
        try await queueByFailedRepair(engine, "/Share/a.bin")
        let bRequests = nas.rangesRequested("/Share/b.bin").count

        let summary = try await engine.resumeRepair()

        XCTAssertEqual(summary.repaired, ["a.bin"])
        XCTAssertEqual(contents("a.bin"), Self.bytes(4000))
        XCTAssertEqual(contents("b.bin"), Data("bad".utf8))
        XCTAssertEqual(nas.rangesRequested("/Share/b.bin").count, bRequests)
        XCTAssertEqual(try queued(), [])
    }

    func testResumeWithEmptyQueueDoesNothing() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(100))
        let engine = try makeEngine()
        _ = try await engine.run()
        let requests = nas.rangesRequested("/Share/f.bin").count

        let summary = try await engine.resumeRepair()

        XCTAssertEqual(summary, RepairSummary(repaired: [], stillBroken: []))
        XCTAssertEqual(nas.rangesRequested("/Share/f.bin").count, requests)
    }

    func testDownloadAllLeavesQueuedFilesUntouched() async throws {
        nas.addFile("/Share/ok.bin", Self.bytes(3000, seed: 4))
        let engine = try await makeBrokenFile(Self.bytes(4000))
        try await queueByFailedRepair(engine, "/Share/f.bin")
        try await queueByFailedRepair(engine, "/Share/ok.bin")
        nas.addFile("/Share/new.bin", Self.bytes(100))
        _ = try await engine.list(refresh: true)
        let okBytes = contents("ok.bin")
        let requests = nas.rangesRequested("/Share/f.bin").count + nas.rangesRequested("/Share/ok.bin").count

        let report = try await engine.run()

        XCTAssertEqual(contents("new.bin"), Self.bytes(100), "Download All still downloads new files")
        XCTAssertEqual(contents("f.bin"), Data("broken".utf8))
        XCTAssertEqual(contents("ok.bin"), okBytes)
        XCTAssertEqual(nas.rangesRequested("/Share/f.bin").count + nas.rangesRequested("/Share/ok.bin").count,
                       requests)
        XCTAssertEqual(try queued(), ["f.bin", "ok.bin"])
        XCTAssertEqual(report.count(.conflict), 1)
    }

    func testInterruptedRepairIsNeverFinishedByDownloadAll() async throws {
        let engine = try await makeBrokenFile(Self.bytes(4000))
        // A process killed mid-repair leaves the file pending with permission to replace.
        let state = try store()
        try state.queueRepair(["/Share/f.bin"])
        try state.prepareRepair("/Share/f.bin")
        let requests = nas.rangesRequested("/Share/f.bin").count

        _ = try await engine.run()

        XCTAssertEqual(contents("f.bin"), Data("broken".utf8))
        XCTAssertEqual(nas.rangesRequested("/Share/f.bin").count, requests)
        XCTAssertEqual(try state.file("/Share/f.bin")?.replaceExisting, false)
        XCTAssertEqual(try queued(), ["f.bin"])
        let summary = try await engine.resumeRepair()
        XCTAssertEqual(summary.repaired, ["f.bin"])
    }

    func testClearQueueWithdrawsReplacePermission() async throws {
        nas.addFile("/Share/a.bin", Self.bytes(100))
        nas.addFile("/Share/b.bin", Self.bytes(100, seed: 2))
        let engine = try makeEngine()
        _ = try await engine.run()
        let state = try store()
        try state.queueRepair(["/Share/a.bin", "/Share/b.bin"])
        try state.prepareRepair("/Share/a.bin")

        try DownloadEngine.clearRepairQueue(destination: destination, paths: ["/Share/a.bin"])

        XCTAssertEqual(try queued(), ["b.bin"])
        XCTAssertEqual(try state.file("/Share/a.bin")?.replaceExisting, false)
        try await engine.clearRepairQueue()
        XCTAssertEqual(try queued(), [])
    }

    func testMigrationFromV2KeepsRowsAndStartsWithEmptyQueue() throws {
        try Self.makeV2Database(at: destination)

        let store = try StateStore.open(destination: destination)

        XCTAssertEqual(try store.schemaVersion(), StateStore.schemaVersion)
        XCTAssertTrue(try store.fileColumns().contains("repair_queued"))
        let file = try XCTUnwrap(try store.file("/R/a.txt"))
        XCTAssertEqual(file.sha256, "abc")
        XCTAssertEqual(file.note, "kept")
        XCTAssertFalse(file.repairQueued)
    }

    func testMigrationFromV1ReachesV3() throws {
        try SchemaV2Tests.makeV1Database(at: destination)

        let store = try StateStore.open(destination: destination)

        XCTAssertEqual(try store.schemaVersion(), 3)
        XCTAssertTrue(try store.fileColumns().contains("repair_queued"))
        XCTAssertEqual(try store.fileCount(), 1)
    }

    /// The v2 schema (v1 plus checksum columns), with one hashed file.
    static func makeV2Database(at destination: URL) throws {
        try SchemaV2Tests.makeV1Database(at: destination)
        let directory = StateStore.stateDirectory(for: SafeFS.canonical(destination))
        let db = try SQLiteDatabase(path: directory.appending(path: StateStore.databaseName).path)
        try db.execute("""
            ALTER TABLE file ADD COLUMN sha256 TEXT; ALTER TABLE file ADD COLUMN hashed_at REAL;
            ALTER TABLE file ADD COLUMN expected_hash TEXT; ALTER TABLE file ADD COLUMN expected_algo TEXT;
            CREATE TABLE meta(key TEXT PRIMARY KEY, value);
            UPDATE file SET sha256 = 'abc';
            PRAGMA user_version = 2;
            """)
    }
}
