import XCTest
@testable import SynoShareKit

/// Glob selection: `*` within a segment, `**` across segments, on rel_path.
final class GlobTests: XCTestCase {
    private func matches(_ pattern: String, _ path: String) throws -> Bool {
        try Glob(pattern).matches(path)
    }

    func testStarStaysWithinOneSegment() throws {
        XCTAssertTrue(try matches("*.txt", "a.txt"))
        XCTAssertFalse(try matches("*.txt", "dir/a.txt"))
        XCTAssertTrue(try matches("dir/*.txt", "dir/a.txt"))
    }

    func testDoubleStarCrossesSegments() throws {
        XCTAssertTrue(try matches("**/*.mkv", "a.mkv"))
        XCTAssertTrue(try matches("**/*.mkv", "x/y/a.mkv"))
        XCTAssertTrue(try matches("**", "any/thing"))
    }

    func testFolderGlobSelectsEverythingBelowIt() throws {
        XCTAssertTrue(try matches("Movies/**", "Movies/a.mkv"))
        XCTAssertTrue(try matches("Movies/**", "Movies/2024/b.mkv"))
        XCTAssertFalse(try matches("Movies/**", "Movies2/a.mkv"))
    }

    func testQuestionMarkAndLiteralCharacters() throws {
        XCTAssertTrue(try matches("a?c.txt", "abc.txt"))
        XCTAssertFalse(try matches("a?c.txt", "a/c.txt"))
        XCTAssertTrue(try matches("r+b (1).[x]", "r+b (1).[x]"))
        XCTAssertFalse(try matches("a.txt", "abtxt"), "dot is literal")
    }

    func testMatchingIgnoresCase() throws {
        XCTAssertTrue(try matches("movies/*.MKV", "Movies/a.mkv"))
    }
}

/// Repair only the selected files (docs/REPAIR_PLAN.md, R3) against the in-memory NAS.
final class RepairTests: EngineTestCase {
    private func health(_ path: String) throws -> FileHealth? {
        try store().file(path).map(FileHealth.init)
    }

    private func modified(_ relative: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: local(relative).path)[.modificationDate] as? Date
    }

    func testRepairResumesFromPartWithRange() async throws {
        let data = Self.bytes(50_000)
        nas.addFile("/Share/movie.mkv", data)
        let engine = try makeEngine()
        _ = try await engine.run()
        try Data("broken".utf8).write(to: local("movie.mkv"))
        _ = try await engine.verify()
        try data.prefix(20_000).write(to: local("movie.mkv.synoshare.part"))

        let summary = try await engine.repair(paths: ["/Share/movie.mkv"])

        XCTAssertEqual(summary.repaired, ["movie.mkv"])
        XCTAssertEqual(summary.stillBroken, [])
        XCTAssertEqual(nas.rangesRequested("/Share/movie.mkv").last, "bytes=20000-")
        XCTAssertEqual(contents("movie.mkv"), data)
        XCTAssertEqual(try store().file("/Share/movie.mkv")?.sha256, Self.sha256(data))
        XCTAssertEqual(try health("/Share/movie.mkv"), .complete)
    }

    func testServerIgnoringRangeOverwritesWholeFile() async throws {
        let data = Self.bytes(40_000)
        nas.addFile("/Share/f.bin", data)
        let engine = try makeEngine()
        _ = try await engine.run()
        try Self.bytes(40_000, seed: 3).write(to: local("f.bin"))
        _ = try await engine.deepVerify()
        try Data(repeating: 0xFF, count: 10_000).write(to: local("f.bin.synoshare.part"))
        nas.script("/Share/f.bin", [.ignoreRange])

        let summary = try await engine.repair(paths: ["/Share/f.bin"])

        XCTAssertEqual(summary.repaired, ["f.bin"])
        XCTAssertEqual(contents("f.bin"), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("f.bin.synoshare.part").path))
        XCTAssertEqual(try health("/Share/f.bin"), .complete)
    }

    func testFailedRepairLeavesOldFileUntouched() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(5000))
        let engine = try makeEngine()
        _ = try await engine.run()
        let old = Data("old copy".utf8)
        try old.write(to: local("f.bin"))
        _ = try await engine.verify()
        let oldDate = try modified("f.bin")
        nas.script("/Share/f.bin", Array(repeating: .status(500), count: 10))

        let summary = try await engine.repair(paths: ["/Share/f.bin"])

        XCTAssertEqual(summary.repaired, [])
        XCTAssertEqual(summary.stillBroken.map(\.relPath), ["f.bin"])
        XCTAssertEqual(contents("f.bin"), old)
        XCTAssertEqual(try modified("f.bin"), oldDate)
        XCTAssertEqual(try health("/Share/f.bin"), .sizeMismatch, "still broken, still selectable")
        XCTAssertEqual(try store().file("/Share/f.bin")?.replaceExisting, false)
    }

    func testUnselectedFilesAreUntouched() async throws {
        nas.addFile("/Share/a.bin", Self.bytes(4000))
        nas.addFile("/Share/b.bin", Self.bytes(4000, seed: 2))
        nas.addFile("/Share/c.bin", Self.bytes(4000, seed: 3))
        let engine = try makeEngine()
        _ = try await engine.run()
        nas.addFile("/Share/new.bin", Self.bytes(100))
        _ = try await engine.list(refresh: true)
        try Data("bad".utf8).write(to: local("a.bin"))
        try FileManager.default.removeItem(at: local("b.bin"))
        _ = try await engine.verify()
        let cBytes = contents("c.bin")
        let cDate = try modified("c.bin")
        let requestsBefore = nas.rangesRequested("/Share/b.bin").count

        let summary = try await engine.repair(paths: ["/Share/a.bin"])

        XCTAssertEqual(summary.repaired, ["a.bin"])
        XCTAssertEqual(contents("a.bin"), Self.bytes(4000))
        XCTAssertNil(contents("b.bin"), "a broken file that was not selected stays as it is")
        XCTAssertEqual(try health("/Share/b.bin"), .missing)
        XCTAssertEqual(nas.rangesRequested("/Share/b.bin").count, requestsBefore)
        XCTAssertNil(contents("new.bin"), "other pending files are not downloaded")
        XCTAssertTrue(nas.rangesRequested("/Share/new.bin").isEmpty)
        XCTAssertEqual(contents("c.bin"), cBytes)
        XCTAssertEqual(try modified("c.bin"), cDate)
    }

    func testManifestMismatchAfterRepairStaysBrokenAndKeepsOldFile() async throws {
        nas.addFile("/Share/f.bin", Self.bytes(5000))
        let engine = try makeEngine()
        _ = try await engine.run()
        let old = Data("old".utf8)
        try old.write(to: local("f.bin"))
        _ = try await engine.verify()
        _ = try await engine.importManifest("\(Self.sha256(Self.bytes(5000, seed: 9)))  f.bin")

        let summary = try await engine.repair(paths: ["/Share/f.bin"])

        XCTAssertEqual(summary.repaired, [])
        XCTAssertEqual(summary.stillBroken.first?.relPath, "f.bin")
        XCTAssertTrue(summary.stillBroken.first?.message.lowercased().contains("checksum") == true)
        XCTAssertEqual(contents("f.bin"), old, "the part is checked before it may replace the old file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("f.bin.synoshare.part").path))
        XCTAssertEqual(try health("/Share/f.bin").map(\.isBroken), true)
    }

    func testMD5ManifestMatchingAfterRepairSucceeds() async throws {
        let data = Self.bytes(5000)
        nas.addFile("/Share/f.bin", data)
        let engine = try makeEngine()
        _ = try await engine.run()
        try Data("x".utf8).write(to: local("f.bin"))
        _ = try await engine.verify()
        _ = try await engine.importManifest("\(Self.md5(data))  f.bin")

        let summary = try await engine.repair(paths: ["/Share/f.bin"])

        XCTAssertEqual(summary.repaired, ["f.bin"])
        XCTAssertEqual(try health("/Share/f.bin"), .complete)
    }

    func testRepairDownloadsMissingFile() async throws {
        nas.addFile("/Share/d/f.txt", Data("abc".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()
        try FileManager.default.removeItem(at: local("d/f.txt"))
        _ = try await engine.verify()

        let selection = try await engine.fileEntries(matching: FileFilter(health: FileHealth.broken, glob: "d/**"))
        let summary = try await engine.repair(paths: selection.map(\.record.path))

        XCTAssertEqual(summary.repaired, ["d/f.txt"])
        XCTAssertEqual(contents("d/f.txt"), Data("abc".utf8))
    }

    func testUnknownAndUnsafePathsAreReportedNotRepaired() async throws {
        nas.addFile("/Share/ok.txt", Data("ok".utf8))
        nas.addRawEntry(in: "/Share", name: "bad\u{7}name")
        let engine = try makeEngine()
        _ = try await engine.run()

        let summary = try await engine.repair(paths: ["/Share/nope.txt", "/Share/bad\u{7}name"])

        XCTAssertEqual(summary.repaired, [])
        XCTAssertEqual(summary.stillBroken.map(\.message), ["unknown file", "unsafe file name; cannot be saved"])
    }

    func testFileFilterCombinesHealthAndGlob() async throws {
        nas.addFile("/Share/m/a.mkv", Data("a".utf8))
        nas.addFile("/Share/m/b.txt", Data("b".utf8))
        nas.addFile("/Share/c.mkv", Data("c".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()

        let mkv = try await engine.fileEntries(matching: FileFilter(glob: "**/*.mkv"))
        let folder = try await engine.fileEntries(matching: FileFilter(health: [.complete], glob: "m/**"))
        let none = try await engine.fileEntries(matching: FileFilter(health: FileHealth.broken, glob: "m/**"))

        XCTAssertEqual(mkv.map(\.record.relPath), ["c.mkv", "m/a.mkv"])
        XCTAssertEqual(folder.map(\.record.relPath), ["m/a.mkv", "m/b.txt"])
        XCTAssertEqual(none, [])
    }
}
