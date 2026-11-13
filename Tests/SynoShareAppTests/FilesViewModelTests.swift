import XCTest
@testable import SynoShareAppCore
@testable import SynoShareKit

@MainActor
final class FilesViewModelTests: XCTestCase {
    var defaults: UserDefaults!
    var suiteName: String!
    var destination: URL!
    var recorder: EngineRecorder!
    var offline: FakeOfflineReader!

    let entries: [FileEntry] = [
        .fake("a/ok.bin", .complete, size: 10),
        .fake("a/gone.bin", .missing, size: 20),
        .fake("a/short.bin", .sizeMismatch, size: 30),
        .fake("b/bad.bin", .checksumMismatch, size: 40),
        .fake("b/plain.bin", .unchecked, size: 50),
        .fake("b/todo.bin", .notDownloaded, size: 60),
    ]

    override func setUp() async throws {
        suiteName = "SynoShareFilesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        destination = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        recorder = EngineRecorder()
        offline = FakeOfflineReader()
        offline.storedEntries = entries
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: destination)
    }

    private func makeModels(password: String = "secret") -> (DownloadViewModel, FilesViewModel) {
        let preferences = AppPreferences(defaults: defaults)
        preferences.shareURL = DownloadViewModelTests.link
        preferences.destination = destination
        let download = DownloadViewModel(preferences: preferences, passwordStore: MemoryPasswordStore(),
                                         offline: offline, makeEngine: recorder.factory, refreshInterval: 0)
        download.password = password
        return (download, FilesViewModel(download: download, offline: offline))
    }

    private func loadedModel() async -> FilesViewModel {
        let (_, files) = makeModels()
        await files.load()
        return files
    }

    private func paths(_ relPaths: String...) -> Set<String> { Set(relPaths.map { "/S/\($0)" }) }

    // MARK: Loading and empty states

    func testLoadListsEveryFileSortedByPath() async {
        let files = await loadedModel()

        XCTAssertTrue(files.hasState)
        XCTAssertEqual(files.rows.count, 6)
        XCTAssertEqual(files.rows.first?.relPath, "a/gone.bin")
        XCTAssertEqual(files.emptyState, nil)
    }

    func testNoStateAtDestinationShowsEmptyState() async {
        offline.stateExists = false
        let files = await loadedModel()

        XCTAssertFalse(files.hasState)
        XCTAssertTrue(files.rows.isEmpty)
        XCTAssertEqual(files.emptyState, .noState)
    }

    func testNoMatchingFilesShowsEmptyState() async {
        let files = await loadedModel()

        files.globText = "zzz/**"

        XCTAssertTrue(files.rows.isEmpty)
        XCTAssertEqual(files.emptyState, .noMatches)
    }

    // MARK: Filters

    func testSegmentsFilterByHealth() async {
        let files = await loadedModel()

        files.segment = .broken
        XCTAssertEqual(Set(files.rows.map(\.id)), paths("a/gone.bin", "a/short.bin", "b/bad.bin"))
        files.segment = .ok
        XCTAssertEqual(files.rows.map(\.relPath), ["a/ok.bin"])
        files.segment = .unchecked
        XCTAssertEqual(files.rows.map(\.relPath), ["b/plain.bin"])
        files.segment = .checksum
        XCTAssertEqual(files.rows.map(\.relPath), ["b/bad.bin"])
        files.segment = .all
        XCTAssertEqual(files.rows.count, 6)
    }

    func testGlobNarrowsTheSegment() async {
        let files = await loadedModel()

        files.segment = .broken
        files.globText = "a/**"

        XCTAssertEqual(Set(files.rows.map(\.id)), paths("a/gone.bin", "a/short.bin"))
        XCTAssertNil(files.globError)
    }

    func testLeadingSlashGlobShowsInlineErrorAndKeepsRows() async {
        let files = await loadedModel()

        files.globText = "/a/**"

        XCTAssertNotNil(files.globError)
        XCTAssertEqual(files.rows.count, 6, "an invalid pattern does not hide everything")
    }

    func testSortByOtherColumns() async {
        let files = await loadedModel()

        files.sortOrder = [KeyPathComparator(\FileRow.size, order: .reverse)]

        XCTAssertEqual(files.rows.first?.relPath, "b/todo.bin")
    }

    // MARK: Selection

    func testSelectAllBrokenStaysWithinTheCurrentFilter() async {
        let files = await loadedModel()
        files.globText = "b/**"

        files.selectAllBroken()

        XCTAssertEqual(files.selection, paths("b/bad.bin"))
    }

    func testSelectAllVisibleToggleAndClear() async {
        let files = await loadedModel()
        files.segment = .broken

        files.selectAllVisible()
        XCTAssertEqual(files.selection.count, 3)
        files.toggle(paths("a/gone.bin", "a/ok.bin"))
        XCTAssertEqual(files.selection, paths("a/short.bin", "b/bad.bin", "a/ok.bin"))
        files.setSelected("/S/a/ok.bin", false)
        XCTAssertFalse(files.isSelected("/S/a/ok.bin"))
        files.clearSelection()
        XCTAssertTrue(files.selection.isEmpty)
    }

    func testCountsTextShowsBrokenSelectedAndSize() async {
        let files = await loadedModel()

        files.toggle(paths("a/ok.bin", "a/gone.bin"))

        XCTAssertEqual(files.brokenCount, 3)
        XCTAssertEqual(files.selectedBytes, 30)
        XCTAssertEqual(files.countsText, "3 broken · 2 selected (\(Formatting.bytes(30)))")
        XCTAssertEqual(files.repairButtonTitle, "Repair 2 Files")
    }

    func testReplacingIntactFilesNeedsConfirmation() async {
        let files = await loadedModel()

        files.toggle(paths("a/gone.bin"))
        XCTAssertFalse(files.needsReplaceConfirmation)
        files.toggle(paths("a/ok.bin", "b/plain.bin"))
        XCTAssertTrue(files.needsReplaceConfirmation)
        XCTAssertEqual(files.intactSelectedCount, 2)
    }

    // MARK: Path list

    func testPathListAddsMatchesToSelectionAndReportsUnmatched() async {
        let files = await loadedModel()
        files.toggle(paths("a/ok.bin"))

        files.pathListText = "S/a/gone.bin (20 bytes)\n# note\nnope.bin\nB/BAD.BIN (41 bytes)"
        files.applyPathList()

        XCTAssertEqual(files.selection, paths("a/ok.bin", "a/gone.bin", "b/bad.bin"))
        XCTAssertEqual(files.pathListResult?.matched.count, 2)
        XCTAssertEqual(files.pathListResult?.unmatched, ["nope.bin"])
        XCTAssertEqual(files.pathListResult?.sizeDifferences.map(\.relPath), ["b/bad.bin"])
    }

    func testPathListTellsTheSheetToCloseOnlyWhenEveryLineMatched() async {
        // The sheet stayed open after "Select Listed Files", which looked like a hang (2026-11-13).
        let files = await loadedModel()

        files.pathListText = "a/gone.bin\nB/BAD.BIN (41 bytes)"
        XCTAssertTrue(files.applyPathList(), "all matched: close and show the selection")

        files.pathListText = "a/gone.bin\nnope.bin"
        XCTAssertFalse(files.applyPathList(), "stay open so the unmatched line is visible")
    }

    func testPathListLoadsFromFile() async throws {
        let files = await loadedModel()
        let url = destination.appending(path: "list.txt")
        try "a/gone.bin\n".write(to: url, atomically: true, encoding: .utf8)

        await files.loadPathList(from: url)

        XCTAssertEqual(files.pathListText, "a/gone.bin\n")
    }

    // MARK: Deep Verify and manifest

    func testDeepVerifyRunsOfflineShowsResultAndReloads() async {
        let files = await loadedModel()
        offline.storedEntries = [.fake("a/ok.bin", .complete)]

        await files.deepVerify()

        XCTAssertEqual(offline.deepVerifyRestarts, [false])
        XCTAssertEqual(files.deepVerifyResult?.problems.count, 1)
        XCTAssertFalse(files.isDeepVerifying)
        XCTAssertEqual(files.rows.count, 1, "entries reloaded after verifying")
    }

    func testDeepVerifyCanBeCancelled() async {
        offline.holdDeepVerify = true
        let files = await loadedModel()

        files.startDeepVerify()
        let running = await eventually { files.deepVerifyProgress != nil }
        XCTAssertTrue(running)
        XCTAssertTrue(files.isDeepVerifying)
        XCTAssertFalse(files.canRepair, "no repair while hashing")
        files.cancelDeepVerify()

        let stopped = await eventually { !files.isDeepVerifying }
        XCTAssertTrue(stopped)
        XCTAssertEqual(files.deepVerifyResult?.cancelled, true)
    }

    func testImportManifestReadsFileAndShowsResult() async throws {
        let files = await loadedModel()
        let url = destination.appending(path: "SHA256SUMS")
        try "abc  a/ok.bin\n".write(to: url, atomically: true, encoding: .utf8)

        await files.importManifest(from: url)

        XCTAssertEqual(offline.manifestTexts, ["abc  a/ok.bin\n"])
        XCTAssertEqual(files.manifestResult?.unknownPaths, ["zz.bin"])
        XCTAssertNil(files.error)
    }

    func testUnreadableManifestShowsError() async {
        let files = await loadedModel()

        await files.importManifest(from: destination.appending(path: "missing.txt"))

        XCTAssertNotNil(files.error)
        XCTAssertNil(files.manifestResult)
    }

    // MARK: Repair

    func testRepairNeedsASelection() async {
        let files = await loadedModel()

        XCTAssertFalse(files.canRepair)
        await files.repairSelected()

        let calls = await recorder.engine.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRepairRunsEngineOnSelectionAndShowsSummary() async {
        let (download, files) = makeModels()
        await files.load()
        await recorder.engine.configure(repairResult: .success(RepairSummary(
            repaired: ["a/gone.bin"], stillBroken: [FileIssue(relPath: "a/short.bin", message: "HTTP 404")])))
        files.toggle(paths("a/gone.bin", "a/short.bin"))

        await files.repairSelected()

        let repaired = await recorder.engine.repairedPaths
        XCTAssertEqual(repaired.map(Set.init), [paths("a/gone.bin", "a/short.bin")])
        XCTAssertEqual(files.repairSummary?.repaired, ["a/gone.bin"])
        XCTAssertTrue(files.isRepairResultPresented)
        XCTAssertEqual(files.selection, paths("a/short.bin"), "still-broken files stay selected")
        XCTAssertFalse(files.isRepairing)
        XCTAssertFalse(download.isBusy)
        XCTAssertEqual(recorder.configurations.first?.destination, destination)
    }

    func testRepairPausesAndStopsTheRunningDownloadFirst() async {
        await recorder.engine.configure(holdRun: true)
        let (download, files) = makeModels()
        await files.load()
        download.startDownload()
        let started = await eventually { await self.recorder.engine.calls.contains("run") }
        XCTAssertTrue(started)
        files.toggle(paths("a/gone.bin"))

        await files.repairSelected()

        let calls = await recorder.engine.calls
        XCTAssertEqual(calls, ["run", "pause", "stop", "repair"])
        XCTAssertFalse(download.isRunning)
        XCTAssertNotNil(files.repairSummary)
    }

    func testQuitWaitsForARepairToSettle() async {
        await recorder.engine.configure(holdRepair: true)
        let (download, files) = makeModels()
        await files.load()
        files.toggle(paths("a/gone.bin"))
        let repair = Task { await files.repairSelected() }
        let started = await eventually { await self.recorder.engine.calls.contains("repair") }
        XCTAssertTrue(started)

        await download.shutdown()

        let calls = await recorder.engine.calls
        XCTAssertEqual(calls, ["repair", "stop", "repairSettled", "shutdown"],
                       "quitting must not cut off the repair's re-verification")
        await repair.value
    }

    func testRepairShowsSpeedAndTimeLeftAndCanBePausedResumedAndStopped() async {
        // A 13.9 GB repair had no ETA or Pause in the Files window (2026-11-13).
        await recorder.engine.configure(holdRepair: true)
        let (download, files) = makeModels()
        await files.load()
        files.toggle(paths("a/gone.bin"))
        let repair = Task { await files.repairSelected() }
        let started = await eventually { await self.recorder.engine.calls.contains("repair") }
        XCTAssertTrue(started)

        download.handle(.phase(.downloading))
        download.handle(.progress(ProgressSnapshot(totalBytes: 1_000, completedBytes: 250, bytesPerSecond: 50,
                                                   active: [], concurrency: 1)))
        XCTAssertTrue(files.repairSpeedText.hasSuffix("/s"))
        XCTAssertEqual(files.repairTimeLeft, "15s")

        await files.toggleRepairPause()
        download.handle(.phase(.paused([.user])))
        XCTAssertTrue(files.isRepairPaused)
        XCTAssertEqual(files.repairTimeLeft, "—")
        await files.toggleRepairPause()

        await files.stopRepair()
        await repair.value

        let calls = await recorder.engine.calls
        XCTAssertEqual(calls, ["repair", "pause", "resume", "stop", "repairSettled"])
        XCTAssertFalse(files.isRepairing)
    }

    func testRepairWithoutPasswordShowsErrorAndDoesNotRun() async {
        let (_, files) = makeModels(password: "")
        await files.load()
        files.toggle(paths("a/gone.bin"))

        await files.repairSelected()

        XCTAssertEqual(files.error?.field, .password)
        XCTAssertNil(files.repairSummary)
        let calls = await recorder.engine.calls
        XCTAssertFalse(calls.contains("repair"))
    }

    func testRepairFailureIsShownAndEndsBusyState() async {
        let (download, files) = makeModels()
        await files.load()
        await recorder.engine.configure(repairResult: .failure(URLError(.notConnectedToInternet)))
        files.toggle(paths("a/gone.bin"))

        await files.repairSelected()

        XCTAssertNotNil(files.error)
        XCTAssertFalse(files.isRepairing)
        XCTAssertFalse(download.isBusy)
    }
}

final class FileRowTests: XCTestCase {
    func testEveryHealthHasTextAndSymbol() {
        for health in FileHealth.allCases {
            let row = FileRow(entry: .fake("x", health))
            XCTAssertFalse(row.statusTitle.isEmpty)
            XCTAssertFalse(row.statusSymbol.isEmpty)
        }
        XCTAssertEqual(FileRow(entry: .fake("x", .complete)).statusSymbol, "checkmark.circle")
        XCTAssertEqual(FileRow(entry: .fake("x", .missing)).statusTitle, "Missing")
        XCTAssertEqual(FileRow(entry: .fake("x", .sizeMismatch)).statusSymbol, "ruler")
    }

    func testIntegrityNoteMentionsChecksumsAndDeepVerify() {
        XCTAssertTrue(Report.integrityNote.contains("SHA-256"))
        XCTAssertTrue(Report.integrityNote.contains("Deep Verify"))
    }
}
