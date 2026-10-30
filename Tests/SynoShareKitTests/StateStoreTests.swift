import XCTest
@testable import SynoShareKit

final class StateStoreTests: XCTestCase {
    private var destination: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        destination = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        store = try StateStore.open(destination: destination)
        try store.bind(to: try ShareLink(serverID: "Srv", linkID: "Link1"))
        try store.setRoot("/R")
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: destination)
    }

    private func entry(_ name: String, size: Int64 = 10, mtime: Double = 1000, dir: Bool = false) -> MappedEntry {
        MappedEntry(entry: ShareEntry(name: name, path: "/R/" + name, isDirectory: dir, size: size,
                                      modified: Date(timeIntervalSince1970: mtime)),
                    relPath: name, localPath: name, renamed: false)
    }

    func testBindingIsStableAndRejectsOtherShare() throws {
        XCTAssertNoThrow(try store.bind(to: try ShareLink(serverID: "Srv", linkID: "Link1")))
        XCTAssertThrowsError(try store.bind(to: try ShareLink(serverID: "Srv", linkID: "Link2")))
        XCTAssertEqual(try store.job()?.root, "/R")
        XCTAssertEqual(try store.job()?.linkID, "Link1")
    }

    func testListingIsResumableAndCompletes() throws {
        XCTAssertFalse(try store.isListingComplete)
        XCTAssertEqual(try store.nextUnlistedFolder()?.path, "/R")
        _ = try store.applyListing(folder: "/R", entries: [entry("sub", dir: true), entry("a.txt")])
        XCTAssertEqual(try store.nextUnlistedFolder()?.path, "/R/sub")
        XCTAssertEqual(try store.childLocalPaths(of: "/R"), ["/R/sub": "sub", "/R/a.txt": "a.txt"])
        _ = try store.applyListing(folder: "/R/sub", entries: [])
        XCTAssertTrue(try store.isListingComplete)
        try store.resetListing()
        XCTAssertFalse(try store.isListingComplete)
        XCTAssertEqual(try store.files(status: .pending).count, 1)
    }

    func testRelistUnchangedKeepsStatus() throws {
        _ = try store.applyListing(folder: "/R", entries: [entry("a.txt")])
        try store.markComplete("/R/a.txt", status: .done, bytes: 10)
        let changed = try store.applyListing(folder: "/R", entries: [entry("a.txt")])
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(try store.file("/R/a.txt")?.status, .done)
    }

    func testChangedAfterCompletionBecomesChangedOnServer() throws {
        _ = try store.applyListing(folder: "/R", entries: [entry("a.txt")])
        try store.markComplete("/R/a.txt", status: .done, bytes: 10)
        let changed = try store.applyListing(folder: "/R", entries: [entry("a.txt", size: 11)])
        XCTAssertEqual(changed.first?.status, .done)
        let record = try store.file("/R/a.txt")
        XCTAssertEqual(record?.status, .changedOnServer)
        XCTAssertEqual(record?.size, 11)
    }

    func testChangedWhileUnfinishedRestarts() throws {
        _ = try store.applyListing(folder: "/R", entries: [entry("a.txt")])
        try store.markDownloading("/R/a.txt")
        try store.markInterrupted("/R/a.txt", bytes: 5)
        XCTAssertEqual(try store.file("/R/a.txt")?.bytesDone, 5)
        _ = try store.applyListing(folder: "/R", entries: [entry("a.txt", mtime: 2000)])
        let record = try store.file("/R/a.txt")
        XCTAssertEqual(record?.status, .pending)
        XCTAssertEqual(record?.bytesDone, 0)
        XCTAssertEqual(record?.mtime, 2000)
    }

    func testChangedStatusTable() {
        XCTAssertEqual(StateStore.changedStatus(from: .done), .changedOnServer)
        XCTAssertEqual(StateStore.changedStatus(from: .adopted), .changedOnServer)
        XCTAssertEqual(StateStore.changedStatus(from: .failed), .pending)
        XCTAssertEqual(StateStore.changedStatus(from: .downloading), .pending)
        XCTAssertEqual(StateStore.changedStatus(from: .conflict), .conflict)
        XCTAssertEqual(StateStore.changedStatus(from: .skippedUnsafe), .skippedUnsafe)
    }

    func testFailureRetryAndInterruptTransitions() throws {
        _ = try store.applyListing(folder: "/R", entries: [entry("a.txt"), entry("b.txt")])
        try store.recordFailure("/R/a.txt", attempts: 8, error: "HTTP 500", final: true)
        try store.markDownloading("/R/b.txt")
        try store.resetInterrupted()
        XCTAssertEqual(try store.file("/R/b.txt")?.status, .pending)
        XCTAssertEqual(try store.file("/R/a.txt")?.lastError, "HTTP 500")
        XCTAssertEqual(try store.resetFailed(), 1)
        let record = try store.file("/R/a.txt")
        XCTAssertEqual(record?.status, .pending)
        XCTAssertEqual(record?.attempts, 0)
        XCTAssertNil(record?.lastError)
    }

    func testUnsafeEntriesAreRecordedAsSkipped() throws {
        let unsafe = MappedEntry(entry: ShareEntry(name: "..", path: "/R/..", isDirectory: true, size: 0, modified: nil),
                                 relPath: "..", localPath: nil, renamed: false)
        _ = try store.applyListing(folder: "/R", entries: [unsafe])
        XCTAssertEqual(try store.files(status: .skippedUnsafe).first?.note, "unsafe folder name; contents skipped")
        XCTAssertNil(try store.nextUnlistedFolder())
    }

    func testResolveConflict() throws {
        _ = try store.applyListing(folder: "/R", entries: [entry("a.txt"), entry("b.txt")])
        XCTAssertThrowsError(try store.resolveConflict("/R/a.txt", .replace), "not in conflict")
        XCTAssertThrowsError(try store.resolveConflict("/R/zzz", .replace))
        try store.markConflict("/R/a.txt", note: "x")
        try store.resolveConflict("/R/a.txt", .replace)
        XCTAssertEqual(try store.file("/R/a.txt")?.replaceExisting, true)
        XCTAssertEqual(try store.file("/R/a.txt")?.status, .pending)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data().write(to: destination.appending(path: "b (2).txt"))
        try store.markConflict("/R/b.txt", note: "x")
        try store.resolveConflict("/R/b.txt", .keepBoth)
        XCTAssertEqual(try store.file("/R/b.txt")?.localPath, "b (3).txt", "skips names taken on disk")
    }

    func testOpenWithoutStateFailsWhenNotCreating() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "none-\(UUID().uuidString)")
        XCTAssertThrowsError(try StateStore.open(destination: empty, create: false))
    }

    func testLargestFileAndCount() throws {
        _ = try store.applyListing(folder: "/R", entries: [entry("a", size: 5), entry("b", size: 50)])
        XCTAssertEqual(try store.largestFile()?.path, "/R/b")
        XCTAssertEqual(try store.fileCount(), 2)
    }

    func testReportCountsAndRoundsUp() throws {
        _ = try store.applyListing(folder: "/R", entries: [entry("a", size: 1), entry("b", size: 200_000),
                                                           entry("c", size: 7)])
        try store.markComplete("/R/a", status: .done, bytes: 1)
        try store.markComplete("/R/c", status: .adopted, bytes: 7, note: "adopted (size-only)")
        let report = try Report.make(store: store)
        XCTAssertEqual(report.files, 3)
        XCTAssertEqual(report.folders, 1)
        XCTAssertEqual(report.expectedBytes, 200_008)
        XCTAssertEqual(report.expectedOnDiskBytes, 4 * 131_072)
        XCTAssertEqual(report.completedBytes, 8)
        XCTAssertEqual(report.count(.pending), 1)
        XCTAssertEqual(report.count(.adopted), 1)
        XCTAssertTrue(report.text.contains("Done: 1"))
    }
}

final class SafeFSTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "safefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRefusesSymlinkedFolder() throws {
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"),
                                                   withDestinationURL: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try SafeFS.ensureDirectory(root: root, relative: "link/x"))
        XCTAssertNoThrow(try SafeFS.ensureDirectory(root: root, relative: "a/b/c"))
    }

    func testRefusesSymlinkedFile() throws {
        let target = root.appending(path: "target")
        try Data("t".utf8).write(to: target)
        let link = root.appending(path: "f.part")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try SafeFS.regularFileSize(link))
        XCTAssertThrowsError(try SafeFS.openForWriting(link, at: 0))
        XCTAssertEqual(try Data(contentsOf: target), Data("t".utf8))
    }

    func testMoveNeverReplacesUnlessAsked() throws {
        let source = root.appending(path: "s")
        let target = root.appending(path: "t")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: target)
        XCTAssertThrowsError(try SafeFS.move(source, to: target, replacing: false))
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        try SafeFS.move(source, to: target, replacing: true)
        XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
    }

    func testWriteSyncAndDate() throws {
        let url = root.appending(path: "w")
        let descriptor = try SafeFS.openForWriting(url, at: 0)
        try SafeFS.write(Data("abc".utf8), to: descriptor, path: url.path)
        try SafeFS.fullSync(descriptor, path: url.path)
        close(descriptor)
        try SafeFS.setModificationDate(Date(timeIntervalSince1970: 1_000_000), of: url)
        let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(try SafeFS.regularFileSize(url), 3)
        try SafeFS.remove(url)
        XCTAssertNil(try SafeFS.regularFileSize(url))
        XCTAssertNoThrow(try SafeFS.remove(url))
    }
}
