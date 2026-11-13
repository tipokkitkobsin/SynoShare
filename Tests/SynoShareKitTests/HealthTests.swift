import XCTest
@testable import SynoShareKit

/// Health classification (docs/REPAIR_PLAN.md defaults) from one state DB row.
final class FileHealthTests: XCTestCase {
    private func record(status: FileStatus, sha256: String? = nil, hashed: Bool = false,
                        lastError: String? = nil, expected: ExpectedHash? = nil) -> FileRecord {
        var columns: [String: SQLValue] = [
            "path": .text("/R/a"), "parent": .text("/R"), "rel_path": .text("a"), "local_path": .text("a"),
            "size": .integer(3), "status": .text(status.rawValue),
            "sha256": SQLValue(sha256), "last_error": SQLValue(lastError),
            "hashed_at": hashed ? .real(1000) : .null,
        ]
        if let expected {
            columns["expected_hash"] = .text(expected.hex)
            columns["expected_algo"] = .text(expected.algorithm.rawValue)
        }
        return FileRecord(row: SQLRow(columns: columns))
    }

    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)

    func testCompleteNeedsARecordedHash() {
        XCTAssertEqual(FileHealth(record(status: .done, sha256: hashA, hashed: true)), .complete)
        XCTAssertEqual(FileHealth(record(status: .done)), .unchecked)
        XCTAssertEqual(FileHealth(record(status: .adopted)), .unchecked, "size-only adoption")
        XCTAssertEqual(FileHealth(record(status: .done, sha256: hashA, hashed: false)), .unchecked,
                       "an imported MD5 reference clears hashed_at until Deep Verify runs")
    }

    func testMissingAfterVerify() {
        XCTAssertEqual(FileHealth(record(status: .pending, lastError: "verify: missing")), .missing)
        XCTAssertEqual(FileHealth(record(status: .done, lastError: "verify: use file (not a regular file)")), .missing)
    }

    func testConflictsAreSizeMismatches() {
        XCTAssertEqual(FileHealth(record(status: .conflict, lastError: "verify: size 8, expected 3")), .sizeMismatch)
        XCTAssertEqual(FileHealth(record(status: .conflict)), .sizeMismatch)
        XCTAssertEqual(FileHealth(record(status: .changedOnServer)), .sizeMismatch)
    }

    func testChecksumMismatchFromVerifyOrManifest() {
        XCTAssertEqual(FileHealth(record(status: .conflict, lastError: "verify: checksum mismatch (sha256)")),
                       .checksumMismatch)
        let manifest = ExpectedHash(algorithm: .sha256, hex: hashB)
        XCTAssertEqual(FileHealth(record(status: .done, sha256: hashA, hashed: true, expected: manifest)),
                       .checksumMismatch, "manifest hash wins over the recorded download hash")
        XCTAssertEqual(FileHealth(record(status: .done, sha256: hashB, hashed: true, expected: manifest)), .complete)
    }

    func testNotDownloaded() {
        for status in [FileStatus.pending, .downloading, .failed, .skippedUnsafe] {
            XCTAssertEqual(FileHealth(record(status: status)), .notDownloaded, status.rawValue)
        }
    }

    func testBrokenSet() {
        XCTAssertEqual(FileHealth.broken, [.missing, .sizeMismatch, .checksumMismatch])
        XCTAssertTrue(FileHealth.checksumMismatch.isBroken)
        XCTAssertFalse(FileHealth.unchecked.isBroken)
    }
}

/// Deep Verify (R2): hash files from disk, baseline or compare, resumable and cancellable.
final class DeepVerifyTests: EngineTestCase {
    func testBaselineIsRecordedForFileWithoutHash() async throws {
        nas.addFile("/Share/f.txt", Data("abc".utf8))
        try Data("xyz".utf8).write(to: local("f.txt"))
        _ = try await makeEngine().run()

        let result = try await DownloadEngine.deepVerify(destination: destination)
        let record = try store().file("/Share/f.txt")

        XCTAssertEqual(result.baselined, 1)
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(record?.sha256, Self.sha256(Data("xyz".utf8)))
        XCTAssertEqual(record.map(FileHealth.init), .complete)
    }

    func testSameSizeCorruptionIsChecksumMismatchAndFileIsUntouched() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(5000))
        _ = try await makeEngine().run()
        let corrupt = Self.bytes(5000, seed: 1)
        try corrupt.write(to: local("f.bin"))

        let result = try await DownloadEngine.deepVerify(destination: destination)
        let record = try store().file("/Share/f.bin")

        XCTAssertEqual(result.problems.map(\.relPath), ["f.bin"])
        XCTAssertEqual(record.map(FileHealth.init), .checksumMismatch)
        XCTAssertEqual(record?.sha256, Self.sha256(Self.bytes(5000)), "the reference hash is kept")
        XCTAssertEqual(contents("f.bin"), corrupt, "never overwritten by verification")
    }

    func testMissingAndWrongSizeAreClassified() async throws {
        nas.addFile("/Share/gone.txt", Data("aaa".utf8))
        nas.addFile("/Share/short.txt", Data("bbb".utf8))
        nas.addFile("/Share/ok.txt", Data("ccc".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()
        try FileManager.default.removeItem(at: local("gone.txt"))
        try Data("b".utf8).write(to: local("short.txt"))

        let result = try await engine.deepVerify()
        let health = try await engine.fileEntries().reduce(into: [String: FileHealth]()) {
            $0[$1.record.relPath] = $1.health
        }

        XCTAssertEqual(result.checked, 3)
        XCTAssertEqual(result.ok, 1)
        XCTAssertEqual(health, ["gone.txt": .missing, "short.txt": .sizeMismatch, "ok.txt": .complete])
    }

    func testFileEntriesFilterByHealth() async throws {
        nas.addFile("/Share/a.txt", Data("aaa".utf8))
        nas.addFile("/Share/b.txt", Data("bbb".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()
        try FileManager.default.removeItem(at: local("b.txt"))
        _ = try await engine.deepVerify()

        let broken = try await engine.fileEntries(matching: FileFilter(health: FileHealth.broken))
        let offline = try DownloadEngine.fileEntries(destination: destination,
                                                     matching: FileFilter(health: [.complete]))

        XCTAssertEqual(broken.map(\.record.relPath), ["b.txt"])
        XCTAssertEqual(offline.map(\.record.relPath), ["a.txt"])
    }

    func testCancelledRunResumesWithoutRehashing() async throws {
        for name in ["a", "b", "c"] { nas.addFile("/Share/\(name).bin", Self.bytes(3000)) }
        _ = try await makeEngine().run()
        let store = try store()
        let stopAfterFirst = Flag()

        let first = try DeepVerifier.run(store: store, isCancelled: { stopAfterFirst.isSet },
                                         progress: { _ in stopAfterFirst.set() })
        let second = try DeepVerifier.run(store: store)

        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(first.checked, 1)
        XCTAssertFalse(second.cancelled)
        XCTAssertEqual(second.skipped, 1, "hashed in the interrupted run, after it started")
        XCTAssertEqual(second.checked, 2)
        XCTAssertNil(try store.deepVerifyStartedAt(), "a finished run clears its resume point")
    }

    func testRestartIgnoresAnInterruptedRun() async throws {
        for name in ["a", "b"] { nas.addFile("/Share/\(name).bin", Self.bytes(3000)) }
        _ = try await makeEngine().run()
        let store = try store()
        let stop = Flag()
        _ = try DeepVerifier.run(store: store, isCancelled: { stop.isSet }, progress: { _ in stop.set() })

        let fresh = try DeepVerifier.run(store: store, restart: true)

        XCTAssertEqual(fresh.skipped, 0)
        XCTAssertEqual(fresh.checked, 2)
    }

    func testCancellingTheCallingTaskStopsDeepVerify() async throws {
        nas.addFile("/Share/a.bin", Self.bytes(3000))
        _ = try await makeEngine().run()

        let destination: URL = destination
        let task = Task { () throws -> DeepVerifyResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DownloadEngine.deepVerify(destination: destination)
        }
        let result = try await task.value

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.checked, 0)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
