import XCTest
@testable import SynoShareAppCore
@testable import SynoShareKit

final class ErrorAdviceTests: XCTestCase {
    func testWrongPasswordGoesToPasswordField() {
        let advice = ErrorAdvice.make(for: SynoError.wrongPassword)
        XCTAssertEqual(advice.field, .password)
        XCTAssertFalse(advice.recovery.isEmpty)
    }

    func testInvalidLinkGoesToURLField() {
        XCTAssertEqual(ErrorAdvice.make(for: SynoError.invalidLink).field, .shareURL)
    }

    func testUnreachableServerGoesToURLFieldWithHint() {
        for error: Error in [URLError(.notConnectedToInternet), URLError(.cannotFindHost),
                             SynoError.serverNotFound("no relay")] {
            let advice = ErrorAdvice.make(for: error)
            XCTAssertEqual(advice.field, .shareURL, "\(error)")
            XCTAssertTrue(advice.message.contains("could not be reached"))
        }
    }

    func testNotEnoughSpaceGoesToDestination() {
        let advice = ErrorAdvice.make(for: PreflightError.insufficientSpace(required: 10, available: 1))
        XCTAssertEqual(advice.field, .destination)
        XCTAssertTrue(advice.recovery.contains("Free up space"))
    }

    func testDiskFullGoesToDestination() {
        let error = LocalFileError(code: ENOSPC, operation: "write", path: "/x")
        XCTAssertEqual(ErrorAdvice.make(for: error).field, .destination)
    }

    func testDestinationBoundToOtherShareGoesToDestination() {
        let error = StateStoreError("This destination already holds a download from a different share link.")
        XCTAssertEqual(ErrorAdvice.make(for: error).field, .destination)
    }

    func testUnknownErrorIsGeneral() {
        XCTAssertEqual(ErrorAdvice.make(for: SynoError.http(status: 500, context: "list")).field, .general)
    }
}

final class FormattingTests: XCTestCase {
    func testETA() {
        XCTAssertEqual(Formatting.eta(nil), "—")
        XCTAssertEqual(Formatting.eta(12), "12s")
        XCTAssertEqual(Formatting.eta(249), "4m 09s")
        XCTAssertEqual(Formatting.eta(3_900), "1h 05m")
    }

    func testSpeedAndPercent() {
        XCTAssertEqual(Formatting.speed(0), "—")
        XCTAssertTrue(Formatting.speed(2 * 1024 * 1024).hasSuffix("/s"))
        XCTAssertEqual(Formatting.percent(0.5), "50.0%")
        XCTAssertEqual(Formatting.percent(2), "100.0%")
        XCTAssertEqual(Formatting.fileName("/Share/dir/a.bin"), "a.bin")
    }
}

final class SummaryRowsTests: XCTestCase {
    func testRowsCoverReportFigures() {
        let report = Report(folders: 3, files: 10, listingComplete: false, expectedBytes: 1_024,
                            expectedOnDiskBytes: 2_048, completedBytes: 512,
                            counts: [.done: 4, .adopted: 2, .failed: 1, .conflict: 1, .changedOnServer: 1,
                                     .skippedUnsafe: 1, .pending: 1],
                            sizeMismatches: 2, renamed: [], failed: [], conflicts: [])
        let rows = Dictionary(uniqueKeysWithValues: SummaryRows.rows(for: report).map { ($0.title, $0.value) })

        XCTAssertEqual(rows["Folders discovered"], "3 (listing incomplete)")
        XCTAssertEqual(rows["Files discovered"], "10")
        XCTAssertEqual(rows["Done"], "6 (2 adopted, size-only)")
        XCTAssertEqual(rows["Failed"], "1")
        XCTAssertEqual(rows["Skipped (unsafe names)"], "1")
        XCTAssertEqual(rows["Conflicts"], "2")
        XCTAssertEqual(rows["Size mismatches"], "2")
        XCTAssertEqual(rows["Expected size"], Formatting.bytes(1_024))
        XCTAssertEqual(rows["Downloaded"], Formatting.bytes(512))
    }
}

final class PreferencesAndOfflineTests: XCTestCase {
    func testPreferencesRoundTripAndDefaults() throws {
        let suite = "SynoSharePrefs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.preventSleep)
        XCTAssertNil(preferences.destination)

        preferences.shareURL = "https://gofile.me/a/b"
        preferences.destination = URL(filePath: "/tmp/x", directoryHint: .isDirectory)
        preferences.preventSleep = false

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.shareURL, "https://gofile.me/a/b")
        XCTAssertEqual(reloaded.destination?.path, "/tmp/x")
        XCTAssertFalse(reloaded.preventSleep)
    }

    func testOfflineReaderReadsRealStateDatabase() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "SynoShareOffline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let reader = OfflineJobReader()
        XCTAssertFalse(reader.hasState(at: destination))

        try StateStore.open(destination: destination).bind(to: ShareLink(serverID: "srv", linkID: "lnk"))

        XCTAssertTrue(reader.hasState(at: destination))
        XCTAssertEqual(try reader.report(at: destination).files, 0)
        XCTAssertEqual(try reader.conflicts(at: destination), [])
        XCTAssertEqual(try reader.verify(at: destination).checked, 0)
    }

    func testConflictItemFromRecordDescribesReason() {
        let item = ConflictItem(path: "/S/a", relPath: "a", detail: "Changed on the server")
        XCTAssertEqual(item.id, "/S/a")
    }

    func testPasswordBoxHoldsLatestValue() {
        let box = PasswordBox()
        XCTAssertEqual(box.get(), "")
        box.set("p")
        XCTAssertEqual(box.get(), "p")
    }
}
