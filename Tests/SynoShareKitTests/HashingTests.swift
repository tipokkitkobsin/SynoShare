import XCTest
@testable import SynoShareKit

/// Schema v2 and the SHA-256 recorded while downloading (docs/REPAIR_PLAN.md, R1).
final class SchemaV2Tests: XCTestCase {
    private var destination: URL!

    override func setUpWithError() throws {
        destination = FileManager.default.temporaryDirectory.appending(path: "schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: destination)
    }

    func testNewDatabaseIsCreatedAtSchemaV2() throws {
        let store = try StateStore.open(destination: destination)

        XCTAssertEqual(try store.schemaVersion(), StateStore.schemaVersion)
        let columns = Set(try store.fileColumns())
        XCTAssertTrue(columns.isSuperset(of: ["sha256", "hashed_at", "expected_hash", "expected_algo"]))
    }

    func testMigratesV1DatabaseAndKeepsRows() throws {
        try Self.makeV1Database(at: destination)

        let store = try StateStore.open(destination: destination)
        let record = try store.file("/R/a.txt")

        XCTAssertEqual(try store.schemaVersion(), StateStore.schemaVersion)
        XCTAssertEqual(record?.status, .done)
        XCTAssertEqual(record?.size, 3)
        XCTAssertEqual(record?.note, "kept")
        XCTAssertNil(record?.sha256)
        XCTAssertNil(record?.hashedAt)
        XCTAssertNil(record?.expectedHash)
    }

    func testReopeningV2DatabaseIsIdempotent() throws {
        try Self.makeV1Database(at: destination)
        _ = try StateStore.open(destination: destination)

        let reopened = try StateStore.open(destination: destination)

        XCTAssertEqual(try reopened.schemaVersion(), StateStore.schemaVersion)
        XCTAssertEqual(try reopened.fileCount(), 1)
    }

    /// The exact v1 schema shipped before hashing existed, with one completed file.
    static func makeV1Database(at destination: URL) throws {
        let directory = StateStore.stateDirectory(for: SafeFS.canonical(destination))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: directory.appending(path: StateStore.databaseName).path)
        try db.execute("""
            CREATE TABLE job(
                id INTEGER PRIMARY KEY CHECK (id = 1),
                share_server_id TEXT NOT NULL, share_link_id TEXT NOT NULL,
                dest TEXT NOT NULL, root TEXT, created_at REAL NOT NULL);
            CREATE TABLE folder(
                path TEXT PRIMARY KEY, parent TEXT, local_path TEXT NOT NULL,
                listed INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE file(
                path TEXT PRIMARY KEY, parent TEXT NOT NULL, rel_path TEXT NOT NULL,
                local_path TEXT NOT NULL, size INTEGER NOT NULL, mtime INTEGER,
                status TEXT NOT NULL, bytes_done INTEGER NOT NULL DEFAULT 0,
                attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, verified_at REAL,
                note TEXT, replace_ok INTEGER NOT NULL DEFAULT 0);
            INSERT INTO file(path, parent, rel_path, local_path, size, status, bytes_done, note)
                VALUES ('/R/a.txt', '/R', 'a.txt', 'a.txt', 3, 'done', 3, 'kept');
            PRAGMA user_version = 1;
            """)
    }
}

final class PartWriterHashTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDigestCoversExistingPrefixAndAppendedBytes() throws {
        let part = directory.appending(path: "f.part")
        try Data("hello ".utf8).write(to: part)
        let writer = try PartWriter(url: part, offset: 6) { _ in }

        try writer.append(Data("world".utf8))

        XCTAssertEqual(writer.sha256Hex(), EngineTestCase.sha256(Data("hello world".utf8)))
        writer.close()
    }

    func testTruncateToZeroResetsDigest() throws {
        let part = directory.appending(path: "f.part")
        try Data(repeating: 0xFF, count: 100).write(to: part)
        let writer = try PartWriter(url: part, offset: 100) { _ in }

        try writer.truncate(to: 0)
        try writer.append(Data("fresh".utf8))

        XCTAssertEqual(writer.sha256Hex(), EngineTestCase.sha256(Data("fresh".utf8)))
        writer.close()
    }

    func testFileHasherMatchesCryptoKitForBothAlgorithms() throws {
        let file = directory.appending(path: "f.bin")
        let data = EngineTestCase.bytes(3 * 1024 * 1024 + 17)
        try data.write(to: file)

        let digests = try FileHasher.digests(of: file, algorithms: [.sha256, .md5])

        XCTAssertEqual(digests[.sha256], EngineTestCase.sha256(data))
        XCTAssertEqual(digests[.md5], EngineTestCase.md5(data))
    }

    func testFileHasherStopsWhenCancelled() throws {
        let file = directory.appending(path: "f.bin")
        try EngineTestCase.bytes(4 * 1024 * 1024).write(to: file)

        XCTAssertThrowsError(try FileHasher.digests(of: file, algorithms: [.sha256], isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}

final class EngineHashingTests: EngineTestCase {
    func testDownloadRecordsSHA256AndHashTime() async throws {
        let data = Self.bytes(70_000)
        nas.addFile("/Share/f.bin", data)

        _ = try await makeEngine().run()
        let record = try store().file("/Share/f.bin")

        XCTAssertEqual(record?.sha256, Self.sha256(data))
        XCTAssertNotNil(record?.hashedAt)
    }

    func testResumedDownloadHashesExistingPartPrefix() async throws {
        let data = Self.bytes(50_000)
        nas.addFile("/Share/movie.mkv", data)
        try data.prefix(20_000).write(to: local("movie.mkv.synoshare.part"))

        _ = try await makeEngine().run()

        XCTAssertEqual(nas.rangesRequested("/Share/movie.mkv"), ["bytes=20000-"])
        XCTAssertEqual(try store().file("/Share/movie.mkv")?.sha256, Self.sha256(data))
    }

    func testServerIgnoringRangeResetsTheHash() async throws {
        let data = Self.bytes(40_000)
        nas.addFile("/Share/f.bin", data)
        nas.script("/Share/f.bin", [.ignoreRange])
        try Data(repeating: 0xFF, count: 10_000).write(to: local("f.bin.synoshare.part"))

        _ = try await makeEngine().run()

        XCTAssertEqual(try store().file("/Share/f.bin")?.sha256, Self.sha256(data))
    }

    func testDroppedConnectionResumeStillHashesWholeFile() async throws {
        let data = Self.bytes(80_000)
        nas.addFile("/Share/f.bin", data)
        nas.script("/Share/f.bin", [.dropAfter(32_768)])

        _ = try await makeEngine().run()

        XCTAssertEqual(try store().file("/Share/f.bin")?.sha256, Self.sha256(data))
    }

    func testAdoptedFileHasNoRecordedHash() async throws {
        nas.addFile("/Share/f.txt", Data("abc".utf8))
        try Data("xyz".utf8).write(to: local("f.txt"))

        _ = try await makeEngine().run()

        XCTAssertNil(try store().file("/Share/f.txt")?.sha256, "size-only adoption never claims a hash")
    }
}
