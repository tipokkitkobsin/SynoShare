import XCTest
@testable import SynoShareKit

/// Selecting files from a pasted list of paths (one per line).
final class PathListTests: XCTestCase {
    private func entry(_ relPath: String, size: Int64 = 10, root: String = "/ShareRoot") -> FileEntry {
        FileEntry(record: FileRecord(row: SQLRow(columns: [
            "path": .text("\(root)/\(relPath)"), "parent": .text(root), "rel_path": .text(relPath),
            "local_path": .text(relPath), "size": .integer(size), "status": .text("done"),
        ])))
    }

    func testParseTrimsSkipsCommentsAndReadsSizeAnnotation() {
        let lines = PathList.parse("""
              # files to fetch again

            ShareRoot/81-000101/Lasfile/81-000101.las   (1,234,567,890 bytes)
            ./b/c.txt
            d e.bin (12 byte)\t
            """)

        XCTAssertEqual(lines.map(\.path), ["ShareRoot/81-000101/Lasfile/81-000101.las", "b/c.txt", "d e.bin"])
        XCTAssertEqual(lines.map(\.listedSize), [1_234_567_890, nil, 12])
        XCTAssertEqual(lines.map(\.lineNumber), [3, 4, 5])
    }

    func testParenthesesThatAreNotASizeStayInThePath() {
        XCTAssertEqual(PathList.parse("a/report (2).pdf").map(\.path), ["a/report (2).pdf"])
    }

    func testMatchesRelPathIgnoringCase() {
        let entries = [entry("A/x.las"), entry("A/y.las")]

        let selection = PathList.select("a/X.LAS", from: entries)

        XCTAssertEqual(selection.matched, [entries[0]])
        XCTAssertEqual(selection.paths, ["/ShareRoot/A/x.las"])
        XCTAssertTrue(selection.unmatched.isEmpty)
    }

    func testShareRootNamePrefixIsStripped() {
        let entries = [entry("81-1/Lasfile/81-1.las")]

        let selection = PathList.select("ShareRoot/81-1/Lasfile/81-1.las   (10 bytes)", from: entries)

        XCTAssertEqual(selection.matched, entries)
    }

    func testDestinationFolderNamePrefixIsStripped() {
        let entries = [entry("x/a.bin", root: "/Share")]

        let selection = PathList.select("Downloads/x/a.bin", from: entries, rootNames: ["downloads"])

        XCTAssertEqual(selection.matched, entries)
    }

    func testPrefixIsKeptWhenItIsARealTopLevelFolder() {
        let entries = [entry("ShareRoot/a.bin"), entry("a.bin")]

        let selection = PathList.select("ShareRoot/a.bin", from: entries)

        XCTAssertEqual(selection.matched, [entries[0]])
    }

    func testUnmatchedLinesAreReportedAndDuplicatesDropped() {
        let entries = [entry("a.bin")]

        let selection = PathList.select("a.bin\n./a.bin\nA.BIN\nnope.bin\n", from: entries)

        XCTAssertEqual(selection.matched, entries)
        XCTAssertEqual(selection.unmatched, ["nope.bin"])
    }

    func testSizeDifferenceStillSelectsButIsReported() {
        let entries = [entry("a.bin", size: 10), entry("b.bin", size: 5)]

        let selection = PathList.select("a.bin (11 bytes)\nb.bin (5 bytes)", from: entries)

        XCTAssertEqual(selection.matched, entries)
        XCTAssertEqual(selection.sizeDifferences, [PathListSizeDifference(relPath: "a.bin", listed: 11, recorded: 10)])
    }

    func testDecomposedUnicodeMatchesComposed() {
        let entries = [entry("Caf\u{E9}.txt")]

        XCTAssertEqual(PathList.select("Cafe\u{301}.txt", from: entries).matched, entries)
    }
}
