import XCTest
@testable import synoshare
@testable import SynoShareKit

final class FileArgumentsTests: XCTestCase {
    func testHealthListAndGlobBuildTheFilter() throws {
        let arguments = try Arguments(["files", "--dest", "/d", "--health", "missing,size-mismatch", "--match", "a/**"])

        let filter = try arguments.fileFilter()

        XCTAssertEqual(filter.health, [.missing, .sizeMismatch])
        XCTAssertEqual(filter.glob, "a/**")
    }

    func testHealthNamesIgnoreCaseAndAcceptRawValues() throws {
        let arguments = try Arguments(["files", "--health", "ChecksumMismatch, not-downloaded ,unchecked"])

        XCTAssertEqual(try arguments.fileFilter().health, [.checksumMismatch, .notDownloaded, .unchecked])
    }

    func testBrokenFlagSelectsEveryBrokenHealth() throws {
        let arguments = try Arguments(["files", "--broken", "--health", "unchecked"])

        XCTAssertEqual(try arguments.fileFilter().health, FileHealth.broken.union([.unchecked]))
    }

    func testNoOptionsMatchesEverything() throws {
        XCTAssertEqual(try Arguments(["files"]).fileFilter(), FileFilter())
    }

    func testUnknownHealthIsRejectedWithTheValidNames() {
        XCTAssertThrowsError(try Arguments(["files", "--health", "rotten"]).fileFilter()) { error in
            XCTAssertTrue(error.localizedDescription.contains("rotten"))
            XCTAssertTrue(error.localizedDescription.contains("size-mismatch"))
        }
    }

    func testEmptyMatchIsRejected() {
        XCTAssertThrowsError(try Arguments(["files", "--match", " "]).fileFilter())
    }

    func testRepairSelectionNeedsBrokenMatchOrPathsFrom() throws {
        XCTAssertThrowsError(try Arguments(["repair", "u", "--dest", "/d"]).selection(requireAny: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("--broken"))
            XCTAssertTrue(error.localizedDescription.contains("--paths-from"))
        }
        XCTAssertEqual(try Arguments(["repair", "u", "--broken"]).selection(requireAny: true).filter?.health,
                       FileHealth.broken)
        let both = try Arguments(["repair", "u", "--broken", "--match", "x/**"]).selection(requireAny: true)
        XCTAssertEqual(both.filter, FileFilter(health: FileHealth.broken, glob: "x/**"))
        let list = try Arguments(["repair", "u", "--paths-from", "-"]).selection(requireAny: true)
        XCTAssertNil(list.filter, "a list alone selects only the listed files")
        XCTAssertEqual(list.pathsFile, "-")
    }

    func testFilesWithoutOptionsSelectsEverything() throws {
        let selection = try Arguments(["files", "--dest", "/d"]).selection(requireAny: false)

        XCTAssertNil(selection.filter)
        XCTAssertNil(selection.pathsFile)
    }

    func testRestartIsAFlag() throws {
        let arguments = try Arguments(["deep-verify", "--dest", "/d", "--restart"])

        XCTAssertTrue(arguments.flags.contains("--restart"))
        XCTAssertTrue(arguments.positionals.isEmpty)
    }

    func testUsageListsTheNewCommands() {
        for command in ["files", "deep-verify", "import-manifest", "repair", "repair-queue"] {
            XCTAssertTrue(usage.contains("synoshare \(command)"), command)
        }
        XCTAssertTrue(usage.contains("--paths-from"))
        XCTAssertTrue(usage.contains("--queued"))
    }

    func testQueuedAloneIsEnoughForRepair() throws {
        let selection = try Arguments(["repair", "u", "--dest", "/d", "--queued"]).selection(requireAny: true)

        XCTAssertTrue(selection.queued)
        XCTAssertNil(selection.filter)
        XCTAssertNil(selection.pathsFile)
    }

    func testRepairWithoutSelectorMentionsQueued() {
        XCTAssertThrowsError(try Arguments(["repair", "u", "--dest", "/d"]).selection(requireAny: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("--queued"))
        }
    }

    func testClearIsAFlag() throws {
        let arguments = try Arguments(["repair-queue", "--dest", "/d", "--clear"])

        XCTAssertTrue(arguments.flags.contains("--clear"))
    }
}

final class FileSelectionTests: XCTestCase {
    private func entry(_ relPath: String) -> FileEntry {
        FileEntry(record: FileRecord(row: SQLRow(columns: [
            "path": .text("/R/\(relPath)"), "parent": .text("/R"), "rel_path": .text(relPath),
            "local_path": .text(relPath), "size": .integer(10), "status": .text("done"),
        ])))
    }

    func testFilterAndListAreAUnionInListingOrder() {
        let all = [entry("a"), entry("b"), entry("c")]
        let selection = FileSelection(filter: FileFilter(glob: "c"), pathsFile: "list.txt")

        let result = selection.apply(all: all, filtered: [all[2]], listText: "b\nzzz", rootNames: [])

        XCTAssertEqual(result.entries, [all[1], all[2]])
        XCTAssertEqual(result.list?.unmatched, ["zzz"])
    }

    func testQueuedIsAUnionWithFilterAndList() {
        let all = [entry("a"), entry("b"), entry("c"), entry("d")]
        let selection = FileSelection(filter: FileFilter(glob: "c"), pathsFile: "-", queued: true)

        let result = selection.apply(all: all, filtered: [all[2]], listText: "b", queuedPaths: ["/R/d"],
                                     rootNames: [])

        XCTAssertEqual(result.entries, [all[1], all[2], all[3]])
    }

    func testQueuedAloneSelectsOnlyQueuedFiles() {
        let all = [entry("a"), entry("b")]

        let result = FileSelection(filter: nil, pathsFile: nil, queued: true)
            .apply(all: all, filtered: all, listText: nil, queuedPaths: ["/R/b"], rootNames: [])

        XCTAssertEqual(result.entries, [all[1]])
    }

    func testEmptyQueueAloneSelectsNothing() {
        let all = [entry("a")]

        let result = FileSelection(filter: nil, pathsFile: nil, queued: true)
            .apply(all: all, filtered: all, listText: nil, queuedPaths: [], rootNames: [])

        XCTAssertEqual(result.entries, [])
    }

    func testNoFilterAndNoListSelectsEverything() {
        let all = [entry("a"), entry("b")]

        let result = FileSelection(filter: nil, pathsFile: nil).apply(all: all, filtered: all, listText: nil,
                                                                      rootNames: [])

        XCTAssertEqual(result.entries, all)
        XCTAssertNil(result.list)
    }

    func testListAloneSelectsOnlyListedFiles() {
        let all = [entry("a"), entry("b")]

        let result = FileSelection(filter: nil, pathsFile: "-").apply(all: all, filtered: all, listText: "a",
                                                                      rootNames: [])

        XCTAssertEqual(result.entries, [all[0]])
    }

    func testListLinesReportUnmatchedAndSizeDifferences() {
        let selection = PathListSelection(matched: [], unmatched: ["x.bin"], sizeDifferences: [
            PathListSizeDifference(relPath: "a.bin", listed: 11, recorded: 10)])

        XCTAssertEqual(FileListing.pathListLines(selection, limit: 5), [
            "path list: 0 matched, 1 not found, 1 size difference(s)",
            "  not found: x.bin",
            "  size differs: a.bin: listed 11 bytes, recorded 10 bytes",
        ])
    }
}

final class FileListingTests: XCTestCase {
    func testSummaryCountsByHealthInDeclarationOrder() {
        let text = FileListing.summary([.missing, .complete, .missing, .unchecked])

        XCTAssertEqual(text, "4 file(s): 1 complete, 2 missing, 1 unchecked; 2 broken")
    }

    func testSummaryOfNothing() {
        XCTAssertEqual(FileListing.summary([]), "0 file(s)")
    }

    func testLineShowsHealthSizeAndPath() {
        let line = FileListing.line(health: .sizeMismatch, size: 2048, relPath: "a/b.bin")

        XCTAssertTrue(line.hasPrefix("size-mismatch"))
        XCTAssertTrue(line.contains("2 KB"))
        XCTAssertTrue(line.hasSuffix("  a/b.bin"))
    }

    func testManifestResultListsAtMostTheLimitOfUnknownPaths() {
        let result = ManifestImportResult(matched: 3, unknownPaths: ["x", "y", "z"], invalidLines: 1, mismatched: 1)

        let lines = FileListing.manifestLines(result, limit: 2)

        XCTAssertEqual(lines.first, "manifest: 3 matched, 1 already mismatched, 3 unknown path(s), 1 invalid line(s)")
        XCTAssertEqual(Array(lines.dropFirst()), ["  unknown: x", "  unknown: y", "  ... and 1 more"])
    }

    func testQueueLinesListFilesAndTotal() {
        let lines = FileListing.queueLines([(health: .sizeMismatch, size: 2048, relPath: "a.bin"),
                                            (health: .missing, size: 1024, relPath: "b.bin")],
                                           partBytes: 1024, limit: 1)

        XCTAssertEqual(lines.first, "2 file(s) waiting to be repaired, 3 KB (1 KB already downloaded)")
        XCTAssertTrue(lines[1].hasSuffix("  a.bin"))
        XCTAssertEqual(lines.last, "  ... and 1 more")
    }

    func testEmptyQueueLine() {
        XCTAssertEqual(FileListing.queueLines([], partBytes: 0, limit: 5), ["no files are waiting to be repaired"])
    }

    func testRepairSummaryListsRepairedAndStillBroken() {
        let summary = RepairSummary(repaired: ["a.bin"],
                                    stillBroken: [FileIssue(relPath: "b.bin", message: "HTTP 404")])

        XCTAssertEqual(FileListing.repairLines(summary), [
            "repair: 1 repaired, 1 still broken",
            "  repaired: a.bin",
            "  still broken: b.bin: HTTP 404",
        ])
    }
}
