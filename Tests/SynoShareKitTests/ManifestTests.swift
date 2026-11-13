import XCTest
@testable import SynoShareKit

/// `sha256sum` / `md5sum` manifest parsing (docs/REPAIR_PLAN.md defaults).
final class ManifestParserTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)
    private let md5 = String(repeating: "cd", count: 16)

    func testParsesTextAndBinaryModeLines() {
        let result = Manifest.parse("\(sha)  dir/a.txt\n\(md5) *b.bin\n")

        XCTAssertEqual(result.entries, [
            ManifestEntry(path: "dir/a.txt", expected: ExpectedHash(algorithm: .sha256, hex: sha)),
            ManifestEntry(path: "b.bin", expected: ExpectedHash(algorithm: .md5, hex: md5)),
        ])
        XCTAssertEqual(result.invalidLines, [])
    }

    func testNormalisesHexCaseLeadingDotSlashAndCRLF() {
        let result = Manifest.parse("\(sha.uppercased())  ./sub/x y.txt\r\n")

        XCTAssertEqual(result.entries.first?.path, "sub/x y.txt")
        XCTAssertEqual(result.entries.first?.expected.hex, sha)
    }

    func testSkipsBlankAndCommentLinesAndReportsInvalidOnes() {
        let text = """
            # made by sha256sum

            \(sha)  ok.txt
            abc  short.txt
            \(String(repeating: "zz", count: 32))  nothex.txt
            \(sha)
            """

        let result = Manifest.parse(text)

        XCTAssertEqual(result.entries.map(\.path), ["ok.txt"])
        XCTAssertEqual(result.invalidLines, [4, 5, 6])
    }

    func testUnescapesBackslashPrefixedLines() {
        let result = Manifest.parse("\\\(sha)  a\\\\b\\nc.txt\n")

        XCTAssertEqual(result.entries.first?.path, "a\\b\nc.txt")
    }
}

/// Importing a manifest into the state DB and comparing against it.
final class ManifestImportTests: EngineTestCase {
    func testImportMatchesRelativePathsAndReportsUnknownOnes() async throws {
        nas.addFile("/Share/dir/a.txt", Data("aaa".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()
        let text = "\(Self.sha256(Data("aaa".utf8)))  ./dir/a.txt\n\(Self.sha256(Data()))  nope.txt\nbad line\n"

        let result = try await engine.importManifest(text)
        let record = try store().file("/Share/dir/a.txt")

        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.unknownPaths, ["nope.txt"])
        XCTAssertEqual(result.invalidLines, 1)
        XCTAssertEqual(result.mismatched, 0)
        XCTAssertEqual(record?.expectedHash, ExpectedHash(algorithm: .sha256, hex: Self.sha256(Data("aaa".utf8))))
        XCTAssertEqual(record.map(FileHealth.init), .complete)
    }

    func testSHA256ManifestDisagreeingWithDownloadHashMarksBroken() async throws {
        nas.addFile("/Share/a.txt", Data("aaa".utf8))
        _ = try await makeEngine().run()

        let result = try DownloadEngine.importManifest(destination: destination,
                                                       text: "\(Self.sha256(Data("zzz".utf8)))  a.txt")

        XCTAssertEqual(result.mismatched, 1)
        XCTAssertEqual(try store().file("/Share/a.txt").map(FileHealth.init), .checksumMismatch,
                       "the manifest hash wins over the recorded download hash")
    }

    func testMD5ManifestNeedsDeepVerifyThenPasses() async throws {
        nas.addFile("/Share/a.txt", Data("aaa".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()

        _ = try await engine.importManifest("\(Self.md5(Data("aaa".utf8)))  a.txt")
        let before = try store().file("/Share/a.txt").map(FileHealth.init)
        let verify = try await engine.deepVerify()
        let after = try store().file("/Share/a.txt").map(FileHealth.init)

        XCTAssertEqual(before, .unchecked, "an MD5 reference cannot be compared without reading the file")
        XCTAssertEqual(verify.problems, [])
        XCTAssertEqual(after, .complete)
    }

    func testMD5ManifestMismatchFoundByDeepVerify() async throws {
        nas.addFile("/Share/a.txt", Data("aaa".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()

        _ = try await engine.importManifest("\(Self.md5(Data("zzz".utf8)))  a.txt")
        let verify = try await engine.deepVerify()

        XCTAssertEqual(verify.problems.first?.message, "checksum mismatch (md5)")
        XCTAssertEqual(try store().file("/Share/a.txt").map(FileHealth.init), .checksumMismatch)
        XCTAssertEqual(contents("a.txt"), Data("aaa".utf8))
    }

    func testReimportingSameMD5KeepsVerifiedState() async throws {
        nas.addFile("/Share/a.txt", Data("aaa".utf8))
        let engine = try makeEngine()
        _ = try await engine.run()
        let manifest = "\(Self.md5(Data("aaa".utf8)))  a.txt"
        _ = try await engine.importManifest(manifest)
        _ = try await engine.deepVerify()

        _ = try await engine.importManifest(manifest)

        XCTAssertEqual(try store().file("/Share/a.txt").map(FileHealth.init), .complete)
    }
}
