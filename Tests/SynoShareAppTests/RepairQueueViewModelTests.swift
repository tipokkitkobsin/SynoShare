import XCTest
@testable import SynoShareAppCore
@testable import SynoShareKit

/// Resume Repair and Discard in the Files and main windows, with a fake engine and state.
@MainActor
final class RepairQueueViewModelTests: XCTestCase {
    var defaults: UserDefaults!
    var suiteName: String!
    var destination: URL!
    var recorder: EngineRecorder!
    var offline: FakeOfflineReader!

    let entries: [FileEntry] = [
        .fake("a/ok.bin", .complete, size: 10),
        .fake("a/gone.bin", .missing, size: 20, queued: true),
        .fake("a/short.bin", .sizeMismatch, size: 30, queued: true),
        .fake("b/bad.bin", .checksumMismatch, size: 40),
    ]

    override func setUp() async throws {
        suiteName = "SynoShareQueueTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        destination = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        recorder = EngineRecorder()
        offline = FakeOfflineReader()
        offline.storedEntries = entries
        offline.queuedPartBytes = 15
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: destination)
    }

    private func makeModels() async -> (DownloadViewModel, FilesViewModel) {
        let preferences = AppPreferences(defaults: defaults)
        preferences.shareURL = DownloadViewModelTests.link
        preferences.destination = destination
        let download = DownloadViewModel(preferences: preferences, passwordStore: MemoryPasswordStore(),
                                         offline: offline, makeEngine: recorder.factory, refreshInterval: 0)
        download.password = "secret"
        let files = FilesViewModel(download: download, offline: offline)
        await files.load()
        return (download, files)
    }

    func testQueueIsLoadedWithEntries() async {
        let (_, files) = await makeModels()

        XCTAssertEqual(files.queuedRepairs.map(\.record.relPath), ["a/gone.bin", "a/short.bin"])
        XCTAssertEqual(files.queuedRepairBytes, 50)
        XCTAssertEqual(files.queuedPartBytes, 15)
        XCTAssertTrue(files.showsRepairQueueBanner)
        XCTAssertTrue(files.canResumeRepair)
        XCTAssertEqual(files.repairQueueTitle, "2 files waiting to be repaired")
        XCTAssertEqual(files.repairQueueDetail, "\(Formatting.bytes(50)), \(Formatting.bytes(15)) already downloaded")
    }

    func testOneQueuedFileUsesSingular() async {
        offline.storedEntries = [.fake("x.bin", .missing, size: 5, queued: true)]
        let (_, files) = await makeModels()

        XCTAssertEqual(files.repairQueueTitle, "1 file waiting to be repaired")
    }

    func testNoBannerWithoutQueue() async {
        offline.storedEntries = [.fake("a/ok.bin", .complete)]
        let (_, files) = await makeModels()

        XCTAssertFalse(files.showsRepairQueueBanner)
        XCTAssertFalse(files.showsMainWindowRepairNotice)
        XCTAssertFalse(files.canResumeRepair)
    }

    func testQueuedRowsAreMarked() async {
        let (_, files) = await makeModels()

        let marked = files.rows.filter(\.isRepairQueued).map(\.relPath)
        XCTAssertEqual(marked, ["a/gone.bin", "a/short.bin"])
    }

    func testResumeRepairsOnlyQueuedFilesAndShowsSummary() async {
        let (download, files) = await makeModels()
        files.toggle(["/S/b/bad.bin"])
        await recorder.engine.configure(repairResult: .success(RepairSummary(repaired: ["a/gone.bin", "a/short.bin"],
                                                                              stillBroken: [])))
        offline.storedEntries = entries.map { .fake($0.record.relPath, $0.health, size: $0.record.size) }

        await files.resumeRepair()

        let repaired = await recorder.engine.repairedPaths
        XCTAssertEqual(repaired, [["/S/a/gone.bin", "/S/a/short.bin"]])
        XCTAssertTrue(files.isRepairResultPresented)
        XCTAssertEqual(files.selection, ["/S/b/bad.bin"], "the user's selection is left alone")
        XCTAssertEqual(files.queuedRepairs, [], "reloaded after the repair")
        XCTAssertFalse(files.isRepairing)
        XCTAssertFalse(download.isBusy)
    }

    func testResumePausesAndStopsTheRunningDownloadFirst() async {
        await recorder.engine.configure(holdRun: true)
        let (download, files) = await makeModels()
        download.startDownload()
        let started = await eventually { await self.recorder.engine.calls.contains("run") }
        XCTAssertTrue(started)
        XCTAssertFalse(files.showsMainWindowRepairNotice, "no notice while the main download runs")
        XCTAssertTrue(files.showsRepairQueueBanner)

        await files.resumeRepair()

        let calls = await recorder.engine.calls
        XCTAssertEqual(calls, ["run", "pause", "stop", "repair"])
    }

    func testBannerIsHiddenWhileRepairing() async {
        await recorder.engine.configure(holdRepair: true)
        let (download, files) = await makeModels()
        let repair = Task { await files.resumeRepair() }
        let started = await eventually { await self.recorder.engine.calls.contains("repair") }
        XCTAssertTrue(started)

        XCTAssertFalse(files.showsRepairQueueBanner)
        XCTAssertFalse(files.canResumeRepair)
        XCTAssertFalse(files.showsMainWindowRepairNotice)

        await download.stop()
        await repair.value
    }

    func testDiscardClearsTheQueueAndReloads() async {
        let (_, files) = await makeModels()
        offline.entriesAfterClear = entries.map { .fake($0.record.relPath, $0.health, size: $0.record.size) }

        await files.discardRepairQueue()

        XCTAssertEqual(offline.queueClears, 1)
        XCTAssertEqual(files.queuedRepairs, [])
        XCTAssertFalse(files.showsRepairQueueBanner)
    }

    func testDiscardIsRefusedWhileRepairing() async {
        await recorder.engine.configure(holdRepair: true)
        let (download, files) = await makeModels()
        let repair = Task { await files.resumeRepair() }
        _ = await eventually { await self.recorder.engine.calls.contains("repair") }

        await files.discardRepairQueue()

        XCTAssertEqual(offline.queueClears, 0)
        await download.stop()
        await repair.value
    }

    func testMainWindowNoticeWhenIdle() async {
        let (_, files) = await makeModels()

        XCTAssertTrue(files.showsMainWindowRepairNotice)
    }
}
