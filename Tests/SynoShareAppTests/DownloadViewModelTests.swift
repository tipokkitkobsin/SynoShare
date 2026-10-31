import XCTest
@testable import SynoShareAppCore
@testable import SynoShareKit

@MainActor
final class DownloadViewModelTests: XCTestCase {
    static let link = "https://gofile.me/abc123/XyZ789"
    var defaults: UserDefaults!
    var suiteName: String!
    var destination: URL!
    var recorder: EngineRecorder!
    var keychain: MemoryPasswordStore!
    var offline: FakeOfflineReader!

    override func setUp() async throws {
        suiteName = "SynoShareAppTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        destination = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        recorder = EngineRecorder()
        keychain = MemoryPasswordStore()
        offline = FakeOfflineReader()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: destination)
    }

    private func makeModel(url: String = link, password: String = "secret", withDestination: Bool = true) -> DownloadViewModel {
        let preferences = AppPreferences(defaults: defaults)
        preferences.shareURL = url
        if withDestination { preferences.destination = destination }
        let model = DownloadViewModel(preferences: preferences, passwordStore: keychain, offline: offline,
                                      makeEngine: recorder.factory, refreshInterval: 0)
        model.password = password
        return model
    }

    // MARK: Launch and offline state

    func testStartShowsOfflineReportFromExistingState() async {
        let model = makeModel()

        await model.start()

        XCTAssertEqual(model.report, .sample())
        XCTAssertEqual(model.bytesDone, 3_000)
        XCTAssertEqual(model.bytesTotal, 4_000)
        XCTAssertEqual(model.fractionCompleted, 0.75, accuracy: 0.0001)
        XCTAssertNotNil(model.statusMessage)
        XCTAssertTrue(recorder.configurations.isEmpty, "showing saved progress needs no engine")
    }

    func testStartWithoutStateShowsNothing() async {
        offline.stateExists = false
        let model = makeModel()

        await model.start()

        XCTAssertNil(model.report)
        XCTAssertFalse(model.canVerify)
    }

    func testStartRestoresKeychainPasswordAndTurnsRememberOn() async throws {
        try keychain.save("from-keychain", for: "abc123/XyZ789")
        let model = makeModel(password: "")

        await model.start()

        XCTAssertEqual(model.password, "from-keychain")
        XCTAssertTrue(model.rememberPassword)
    }

    func testRememberPasswordDefaultsOff() {
        XCTAssertFalse(makeModel().rememberPassword)
        XCTAssertTrue(makeModel().preventSleep, "prevent sleep defaults on")
    }

    // MARK: Validation

    func testInvalidLinkShowsErrorNextToURLField() async {
        let model = makeModel(url: "https://example.com/nope")

        await model.connect()

        XCTAssertEqual(model.error(for: .shareURL)?.field, .shareURL)
        XCTAssertNil(model.error(for: .password))
        XCTAssertTrue(recorder.configurations.isEmpty)
    }

    func testMissingDestinationShowsErrorNextToDestination() async {
        let model = makeModel(withDestination: false)

        await model.download()

        XCTAssertEqual(model.error(for: .destination), .missingDestination)
    }

    func testEmptyPasswordShowsErrorNextToPassword() async {
        let model = makeModel(password: "")

        await model.download()

        XCTAssertEqual(model.error(for: .password)?.field, .password)
        XCTAssertTrue(recorder.configurations.isEmpty)
    }

    // MARK: Operations

    func testDownloadRunsEngineWithConfiguredOptions() async throws {
        let model = makeModel()
        model.preventSleep = false

        await model.download()

        let calls = await recorder.engine.calls
        XCTAssertEqual(calls, ["run"])
        let configuration = try XCTUnwrap(recorder.configurations.first)
        XCTAssertFalse(configuration.preventSleep)
        XCTAssertEqual(configuration.link.serverID, "abc123")
        XCTAssertEqual(configuration.destination, destination)
        XCTAssertEqual(model.report, .sample())
        XCTAssertNil(model.operation)
        XCTAssertNil(model.error)
    }

    func testPasswordProviderReturnsCurrentPasswordInMemory() async throws {
        let model = makeModel()
        await model.connect()
        model.password = "changed"

        let provider = try XCTUnwrap(recorder.lastProvider)
        let supplied = try await provider()

        XCTAssertEqual(supplied, "changed")
        XCTAssertNil(defaults.dictionaryRepresentation().values.first { "\($0)".contains("changed") },
                     "password never reaches UserDefaults")
    }

    func testEngineIsReusedUntilInputsChange() async {
        let model = makeModel()
        await model.connect()
        await model.download()
        XCTAssertEqual(recorder.configurations.count, 1)

        model.preventSleep = false
        await model.download()

        XCTAssertEqual(recorder.configurations.count, 2)
        let calls = await recorder.engine.calls
        XCTAssertTrue(calls.contains("shutdown"), "old engine is shut down")
    }

    func testWrongPasswordErrorShownNextToPassword() async {
        await recorder.engine.configure(runResult: .failure(SynoError.wrongPassword))
        let model = makeModel()

        await model.connect()

        XCTAssertEqual(model.error(for: .password)?.message, "Wrong share password.")
        XCTAssertNil(model.operation)
    }

    func testRetryFailedCallsEngine() async {
        offline.storedReport = .sample(failed: [FileIssue(relPath: "x.bin", message: "Timed out.")],
                                       counts: [.failed: 1])
        let model = makeModel()
        await model.start()
        XCTAssertTrue(model.canRetryFailed)
        XCTAssertEqual(model.failedFiles.map(\.relPath), ["x.bin"])

        await model.retryFailed()

        let calls = await recorder.engine.calls
        XCTAssertEqual(calls, ["retryFailed"])
    }

    func testPauseResumeAndGracefulShutdownWhileRunning() async {
        await recorder.engine.configure(holdRun: true)
        let model = makeModel()

        model.startDownload()
        let started = await eventually { await self.recorder.engine.calls.contains("run") }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isRunning)

        await model.togglePause()
        model.handle(.phase(.paused([.user])))
        XCTAssertTrue(model.isUserPaused)
        await model.togglePause()

        await model.shutdown()

        let calls = await recorder.engine.calls
        XCTAssertEqual(calls, ["run", "pause", "resume", "stop", "shutdown"])
        XCTAssertFalse(model.isRunning)
    }

    // MARK: Events

    func testProgressEventDrivesNumbers() {
        let model = makeModel()
        let snapshot = ProgressSnapshot(totalBytes: 1_000, completedBytes: 250, bytesPerSecond: 50,
                                        active: [ActiveFile(path: "/S/a.bin", bytesDone: 10, size: 100)],
                                        concurrency: 3)

        model.handle(.progress(snapshot))
        model.handle(.listing(foldersListed: 4, filesKnown: 40))

        XCTAssertEqual(model.fractionCompleted, 0.25, accuracy: 0.0001)
        XCTAssertEqual(model.bytesDone, 250)
        XCTAssertEqual(model.progress?.eta ?? 0, 15, accuracy: 0.0001)
        XCTAssertEqual(model.listing, ListingProgress(folders: 4, files: 40))
    }

    func testTimeLeftShownOnlyWhileDownloading() {
        let model = makeModel()
        model.handle(.progress(ProgressSnapshot(totalBytes: 1_000, completedBytes: 250, bytesPerSecond: 50,
                                                active: [], concurrency: 3)))

        model.handle(.phase(.downloading))
        XCTAssertEqual(model.timeLeft, "15s")

        model.handle(.phase(.paused([.user])))
        XCTAssertEqual(model.timeLeft, "—", "a paused download has no meaningful ETA")
    }

    func testVolumeLossShowsDriveUnpluggedNextToDestination() {
        let model = makeModel()

        model.handle(.phase(.paused([.volumeUnavailable])))

        XCTAssertTrue(model.isDriveUnavailable)
        XCTAssertEqual(model.error(for: .destination), .driveUnplugged)
        XCTAssertEqual(model.phaseDescription, "Paused — drive unavailable")
    }

    func testPasswordSavedToKeychainOnlyAfterLoginWhenRemembered() async {
        let model = makeModel()
        await model.connect()

        model.handle(.phase(.listing))
        XCTAssertTrue(keychain.all.isEmpty, "remember is off by default")

        model.rememberPassword = true
        model.savedPasswordThisRun = false
        model.handle(.phase(.connecting))
        XCTAssertTrue(keychain.all.isEmpty, "not saved before login succeeds")
        model.handle(.phase(.downloading))
        XCTAssertEqual(keychain.all, ["abc123/XyZ789": "secret"])

        model.rememberPassword = false
        XCTAssertTrue(keychain.all.isEmpty, "turning remember off deletes the item")
    }

    // MARK: Conflicts and verify

    func testResolveConflictOfflineWithoutEngine() async {
        let item = ConflictItem(path: "/S/f.txt", relPath: "f.txt", detail: "Local file differs in size")
        offline.storedConflicts = [item]
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.conflicts, [item])

        await model.resolve(item, .keepBoth)

        XCTAssertEqual(offline.resolved, ["/S/f.txt"])
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    func testResolveConflictGoesThroughEngineWhenConnected() async {
        let item = ConflictItem(path: "/S/f.txt", relPath: "f.txt", detail: "x")
        await recorder.engine.configure(conflicts: [item])
        let model = makeModel()
        await model.connect()
        XCTAssertEqual(model.conflicts, [item])

        await model.resolve(item, .replace)

        let resolved = await recorder.engine.resolved
        XCTAssertEqual(resolved.map(\.0), ["/S/f.txt"])
        XCTAssertEqual(resolved.map(\.1), [.replace])
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertTrue(offline.resolved.isEmpty)
    }

    func testVerifyOfflinePresentsSummary() async {
        let model = makeModel()
        await model.start()

        await model.verify()

        XCTAssertEqual(model.verification?.problems.count, 1)
        XCTAssertTrue(model.isSummaryPresented)
        XCTAssertFalse(model.isVerifying)
    }

    func testSetDestinationPersistsPathButNotPassword() async {
        let model = makeModel(withDestination: false)
        await model.setDestination(destination)

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.destination?.path, destination.path)
        XCTAssertEqual(reloaded.shareURL, Self.link)
        XCTAssertEqual(model.report, .sample())
    }
}
