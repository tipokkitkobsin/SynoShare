import XCTest
@testable import SynoShareKit

/// DECISIONS #8 (existing files, conflicts, changes on the server), unsafe names,
/// preflight, pause/stop and offline verify/status.
final class EngineFilesTests: EngineTestCase {
    func testExistingSameSizeFileIsAdoptedNotDownloaded() async throws {
        nas.addFile("/Share/f.txt", Data("abc".utf8))
        try Data("xyz".utf8).write(to: local("f.txt"))
        let engine = try makeEngine()

        let report = try await engine.run()

        XCTAssertEqual(report.count(.adopted), 1)
        XCTAssertEqual(contents("f.txt"), Data("xyz".utf8), "size-only adoption keeps the local file")
        XCTAssertEqual(try store().file("/Share/f.txt")?.note, "adopted (size-only)")
        XCTAssertTrue(nas.rangesRequested("/Share/f.txt").isEmpty)
    }

    func testDifferentSizeFileIsConflictAndNeverOverwritten() async throws {
        nas.addFile("/Share/f.txt", Data("server".utf8))
        try Data("mine".utf8).write(to: local("f.txt"))
        let engine = try makeEngine()

        let report = try await engine.run()

        XCTAssertEqual(report.count(.conflict), 1)
        XCTAssertEqual(contents("f.txt"), Data("mine".utf8))
        XCTAssertEqual(report.conflicts.first?.relPath, "f.txt")
        let conflicts = try await engine.files(status: .conflict, .changedOnServer)
        XCTAssertEqual(conflicts.map(\.path), ["/Share/f.txt"], "remote path needed by resolveConflict")
    }

    func testConflictKeepBothDownloadsToNumberedName() async throws {
        nas.addFile("/Share/f.txt", Data("server".utf8))
        try Data("mine".utf8).write(to: local("f.txt"))
        let engine = try makeEngine()
        _ = try await engine.run()

        try await engine.resolveConflict(path: "/Share/f.txt", resolution: .keepBoth)
        let report = try await engine.run()

        XCTAssertEqual(contents("f.txt"), Data("mine".utf8))
        XCTAssertEqual(contents("f (2).txt"), Data("server".utf8))
        XCTAssertEqual(report.count(.done), 1)
        XCTAssertEqual(report.renamed.first?.message, "saved as f (2).txt")
    }

    func testConflictReplaceOverwritesOnlyAfterUserChoice() async throws {
        nas.addFile("/Share/f.txt", Data("server".utf8))
        try Data("mine".utf8).write(to: local("f.txt"))
        let engine = try makeEngine()
        _ = try await engine.run()

        try await engine.resolveConflict(path: "/Share/f.txt", resolution: .replace)
        _ = try await engine.run()

        XCTAssertEqual(contents("f.txt"), Data("server".utf8))
    }

    func testChangedOnServerAfterCompletionIsTaggedNotOverwritten() async throws {
        nas.addFile("/Share/f.txt", Data("v1".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()
        nas.addFile("/Share/f.txt", Data("version2".utf8), mtime: 1_800_000_000)

        let report = try await engine.list(refresh: true)
        _ = try await engine.run()

        XCTAssertEqual(report.count(.changedOnServer), 1)
        XCTAssertEqual(contents("f.txt"), Data("v1".utf8))
        XCTAssertEqual(try store().file("/Share/f.txt")?.status, .changedOnServer)
    }

    func testChangedOnServerDiscardsStalePart() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(9000))
        let engine = try makeEngine()
        _ = try await engine.list()
        try Self.bytes(3000).write(to: local("f.bin.synoshare.part"))
        let newer = Self.bytes(9000, seed: 99)
        nas.addFile("/Share/f.bin", newer, mtime: 1_800_000_000)

        _ = try await engine.list(refresh: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("f.bin.synoshare.part").path))
        _ = try await engine.run()

        XCTAssertEqual(contents("f.bin"), newer)
    }

    func testCaseInsensitiveCollisionGetsNumberedName() async throws {
        nas.addFile("/Share/Report.txt", Data("upper".utf8))
        nas.addFile("/Share/report.txt", Data("lower".utf8))
        let engine = try makeEngine()

        let report = try await engine.run()

        XCTAssertEqual(report.count(.done), 2)
        XCTAssertEqual(try store().file("/Share/report.txt")?.localPath, "report (2).txt")
        XCTAssertEqual(contents("report (2).txt"), Data("lower".utf8))
        XCTAssertEqual(report.renamed.count, 1)
    }

    func testUnsafeNamesAreSkipped() async throws {
        nas.addFile("/Share/ok.txt", Data("ok".utf8))
        nas.addRawEntry(in: "/Share", name: "..", path: "/Share/..")
        nas.addRawEntry(in: "/Share", name: "bad\u{7}name")
        nas.addRawEntry(in: "/Share", name: "evil", path: "/etc/passwd")
        let engine = try makeEngine()

        let report = try await engine.run()

        XCTAssertEqual(report.count(.done), 1)
        XCTAssertEqual(report.count(.skippedUnsafe), 3)
    }

    func testPreflightRefusesWhenShareDoesNotFit() async throws {
        nas.addRawEntry(in: "/Share", name: "huge.bin", size: 1 << 60)
        let engine = try makeEngine()

        do {
            _ = try await engine.run()
            XCTFail("expected insufficient space")
        } catch let error as PreflightError {
            guard case .insufficientSpace = error else { return XCTFail("wrong error") }
        }
    }

    func testRefusesDestinationOfDifferentShare() throws {
        _ = try makeEngine()
        XCTAssertThrowsError(try makeEngine { $0.link = try! ShareLink(serverID: "Other", linkID: "Different") })
    }

    func testStopLeavesFilesPendingAndResumeFinishes() async throws {
        for index in 0..<6 { nas.addFile("/Share/f\(index).bin", Self.bytes(5000)) }
        nas.script("/Share/f0.bin", Array(repeating: .timeout, count: 3))
        let engine = try makeEngine { $0.retryPolicy = RetryPolicy(baseDelay: 0.5, maxDelay: 0.5, maxAttempts: 8) }
        let run = Task { try await engine.run() }
        for await event in engine.events {
            if case .fileRetrying = event { break }
        }
        await engine.stop()
        _ = try await run.value
        XCTAssertNotEqual(try store().file("/Share/f0.bin")?.status, .done)

        let resumed = try makeEngine()
        let report = try await resumed.run()
        XCTAssertEqual(report.count(.done), 6)
    }

    func testPausesWhileVolumeIsGoneAndResumesWhenBack() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(5000))
        let volume = VolumeFlag()
        volume.set(false)
        let engine = try makeEngine { configuration in configuration.volumeAvailable = { volume.get() } }
        let run = Task { try await engine.run() }
        for await event in engine.events {
            if case .phase(.paused(let reasons)) = event, reasons.contains(.volumeUnavailable) { break }
        }
        XCTAssertNil(contents("f.bin"))

        volume.set(true)
        let report = try await run.value

        XCTAssertEqual(report.count(.done), 1)
    }

    func testUserPauseAndResume() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(5000))
        nas.script("/Share/f.bin", [.timeout])
        let engine = try makeEngine { $0.retryPolicy = RetryPolicy(baseDelay: 0.3, maxDelay: 0.3, maxAttempts: 8) }
        let run = Task { try await engine.run() }
        for await event in engine.events {
            if case .fileRetrying = event { break }
        }
        await engine.pause()
        await engine.resume()
        let report = try await run.value
        XCTAssertEqual(report.count(.done), 1)
    }

    func testOfflineVerifyAndStatus() async throws {
        nas.addFile("/Share/a.txt", Data("aaa".utf8))
        nas.addFile("/Share/b.txt", Data("bbb".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()
        try FileManager.default.removeItem(at: local("b.txt"))

        let result = try DownloadEngine.verify(destination: destination)
        let report = try DownloadEngine.report(destination: destination)

        XCTAssertEqual(result.checked, 2)
        XCTAssertEqual(result.ok, 1)
        XCTAssertEqual(result.problems.first?.message, "missing")
        XCTAssertEqual(report.sizeMismatches, 1)
        XCTAssertNotNil(try store().file("/Share/a.txt")?.verifiedAt)
    }

    func testOfflineReportWithoutStateFails() {
        XCTAssertThrowsError(try DownloadEngine.report(destination: destination))
    }
}

final class VolumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func get() -> Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}
