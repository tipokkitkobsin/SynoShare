import XCTest
@testable import SynoShareKit

final class PathMapperTests: XCTestCase {
    func testSafeNames() {
        XCTAssertTrue(PathMapper.isSafeName("report 2024.pdf"))
        XCTAssertTrue(PathMapper.isSafeName("..hidden"))
        for bad in ["", ".", "..", "a/b", "/abs", "tab\tname", "nul\u{0}x", "del\u{7F}"] {
            XCTAssertFalse(PathMapper.isSafeName(bad), bad)
        }
    }

    func testNumberedNames() {
        XCTAssertEqual(PathMapper.numbered("report.pdf", 2), "report (2).pdf")
        XCTAssertEqual(PathMapper.numbered("archive.tar.gz", 3), "archive.tar (3).gz")
        XCTAssertEqual(PathMapper.numbered(".profile", 2), ".profile (2)")
        XCTAssertEqual(PathMapper.numbered("Folder", 2), "Folder (2)")
    }

    func testUniqueNameSkipsTakenNumbers() {
        let taken: Set<String> = ["a.txt", "a (2).txt"]
        XCTAssertEqual(PathMapper.uniqueName("A.TXT", taken: taken), "A (3).TXT")
        XCTAssertEqual(PathMapper.uniqueName("b.txt", taken: taken), "b.txt")
    }

    func testCollisionKeyIgnoresCaseAndNormalisation() {
        XCTAssertEqual(PathMapper.collisionKey("Cafe\u{301}"), PathMapper.collisionKey("CAF\u{C9}"))
    }

    func testMapChildrenRenamesLaterCollisionAndKeepsExisting() {
        let entries = [entry("b.txt"), entry("B.TXT"), entry("c.txt")]
        let mapped = PathMapper.mapChildren(of: "/S/d", parentRel: "d", parentLocal: "d", entries: entries,
                                            existing: ["/S/d/c.txt": "d/c (2).txt"])
        let byName = Dictionary(uniqueKeysWithValues: mapped.map { ($0.entry.name, $0) })
        XCTAssertEqual(byName["B.TXT"]?.localPath, "d/B.TXT")
        XCTAssertEqual(byName["b.txt"]?.localPath, "d/b (2).txt")
        XCTAssertEqual(byName["b.txt"]?.renamed, true)
        XCTAssertEqual(byName["c.txt"]?.localPath, "d/c (2).txt", "existing mapping is stable")
        XCTAssertEqual(byName["c.txt"]?.relPath, "d/c.txt")
    }

    func testMapChildrenRejectsUnsafeAndInconsistentPaths() {
        let entries = [entry(".."), ShareEntry(name: "x", path: "/elsewhere/x", isDirectory: false, size: 1, modified: nil)]
        let mapped = PathMapper.mapChildren(of: "/S", parentRel: "", parentLocal: "", entries: entries, existing: [:])
        XCTAssertTrue(mapped.allSatisfy { $0.localPath == nil })
    }

    func testRootReservesStateFolderName() {
        let mapped = PathMapper.mapChildren(of: "/S", parentRel: "", parentLocal: "",
                                            entries: [ShareEntry(name: ".SynoShare", path: "/S/.SynoShare",
                                                                 isDirectory: true, size: 0, modified: nil)],
                                            existing: [:])
        XCTAssertEqual(mapped.first?.localPath, ".SynoShare (2)")
    }

    func testPartURL() {
        let url = PathMapper.partURL(for: URL(filePath: "/d/a.bin"))
        XCTAssertEqual(url.path, "/d/a.bin.synoshare.part")
    }

    private func entry(_ name: String, in folder: String = "/S/d") -> ShareEntry {
        ShareEntry(name: name, path: folder + "/" + name, isDirectory: false, size: 1, modified: nil)
    }
}

final class SchedulingPolicyTests: XCTestCase {
    func testBackoffGrowsExponentiallyWithinJitterBounds() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(afterAttempt: 1, random: 0), 0.5)
        XCTAssertEqual(policy.delay(afterAttempt: 1, random: 1), 1)
        XCTAssertEqual(policy.delay(afterAttempt: 4, random: 1), 8)
        XCTAssertEqual(policy.delay(afterAttempt: 4, random: 0.5), 6)
        XCTAssertEqual(policy.delay(afterAttempt: 20, random: 1), 60, "capped at 60 s")
        XCTAssertEqual(policy.delay(afterAttempt: 20, random: 0), 30)
        for attempt in 1...10 {
            let delay = policy.delay(afterAttempt: attempt)
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 60)
        }
    }

    func testGivesUpAfterMaxAttempts() {
        let policy = RetryPolicy()
        XCTAssertFalse(policy.shouldGiveUp(afterAttempts: 7))
        XCTAssertTrue(policy.shouldGiveUp(afterAttempts: 8))
    }

    func testAdaptiveDropsToOneAfterRepeatedThrottlingAndRampsBack() {
        var adaptive = AdaptiveConcurrency(maximum: 3, throttleThreshold: 3, rampUpAfter: 2)
        XCTAssertEqual(adaptive.current, 3)
        adaptive.recordThrottle()
        adaptive.recordThrottle()
        XCTAssertEqual(adaptive.current, 3)
        adaptive.recordThrottle()
        XCTAssertEqual(adaptive.current, 1)
        adaptive.recordSuccess()
        adaptive.recordSuccess()
        XCTAssertEqual(adaptive.current, 2)
        for _ in 0..<10 { adaptive.recordSuccess() }
        XCTAssertEqual(adaptive.current, 3, "never above maximum")
    }

    func testSuccessResetsThrottleStreak() {
        var adaptive = AdaptiveConcurrency(maximum: 3, throttleThreshold: 2)
        adaptive.recordThrottle()
        adaptive.recordSuccess()
        adaptive.recordThrottle()
        XCTAssertEqual(adaptive.current, 3)
    }

    func testSpeedEstimatorSmoothsAndEstimatesETA() {
        var speed = SpeedEstimator(smoothing: 0.5)
        XCTAssertNil(speed.eta(remainingBytes: 10))
        speed.add(bytes: 100, over: 1)
        XCTAssertEqual(speed.bytesPerSecond, 100)
        speed.add(bytes: 300, over: 1)
        XCTAssertEqual(speed.bytesPerSecond, 200)
        speed.add(bytes: 5, over: 0)
        XCTAssertEqual(speed.bytesPerSecond, 200, "zero interval ignored")
        XCTAssertEqual(speed.eta(remainingBytes: 1000), 5)
    }

    func testFailureClassification() {
        XCTAssertEqual(FailureClassifier.classify(DownloadError.sessionExpired), .sessionExpired)
        XCTAssertEqual(FailureClassifier.classify(SynoError.api(code: 119, context: "x")), .sessionExpired)
        XCTAssertEqual(FailureClassifier.classify(DownloadError.throttled(status: 429)), .throttled)
        XCTAssertEqual(FailureClassifier.classify(SynoError.http(status: 503, context: "x")), .throttled)
        XCTAssertEqual(FailureClassifier.classify(URLError(.timedOut)), .throttled)
        XCTAssertEqual(FailureClassifier.classify(URLError(.networkConnectionLost)), .retryable)
        XCTAssertEqual(FailureClassifier.classify(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(FailureClassifier.classify(CancellationError()), .cancelled)
        XCTAssertEqual(FailureClassifier.classify(SynoError.wrongPassword), .fatal)
        XCTAssertEqual(FailureClassifier.classify(LocalFileError(code: ENOSPC, operation: "w", path: "p")), .fatal)
        XCTAssertEqual(FailureClassifier.classify(LocalFileError(code: EIO, operation: "w", path: "p")), .retryable)
        XCTAssertEqual(FailureClassifier.classify(DownloadError.changedOnServer), .changedOnServer)
        XCTAssertEqual(FailureClassifier.classify(SynoError.http(status: 500, context: "x")), .retryable)
    }
}

final class PreflightReportTests: XCTestCase {
    func testRoundsUpToClusters() {
        XCTAssertEqual(Preflight.roundUp(0), 0)
        XCTAssertEqual(Preflight.roundUp(1), 131_072)
        XCTAssertEqual(Preflight.roundUp(131_072), 131_072)
        XCTAssertEqual(Preflight.roundUp(131_073), 262_144)
    }

    func testRemainingBytesSubtractsPartClusters() {
        let remaining = Preflight.remainingBytes([
            (size: 300_000, partBytes: 0),        // 3 clusters
            (size: 300_000, partBytes: 140_000),  // 3 - 2 clusters
            (size: 10, partBytes: 10),            // complete
            (size: 0, partBytes: 0),
        ])
        XCTAssertEqual(remaining, 4 * 131_072)
    }

    func testCheckRefusesWhenInsufficient() {
        XCTAssertNoThrow(try Preflight.check(required: 1000, available: Preflight.reserve + 1000))
        XCTAssertThrowsError(try Preflight.check(required: 1001, available: Preflight.reserve + 1000)) { error in
            XCTAssertEqual(error as? PreflightError,
                           .insufficientSpace(required: Preflight.reserve + 1001, available: Preflight.reserve + 1000))
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    func testAvailableBytesOfTempDirectory() throws {
        XCTAssertGreaterThan(try Preflight.availableBytes(at: FileManager.default.temporaryDirectory), 0)
    }

    func testProgressSnapshotMath() {
        let snapshot = ProgressSnapshot(totalBytes: 1000, completedBytes: 250, bytesPerSecond: 50,
                                        active: [], concurrency: 3)
        XCTAssertEqual(snapshot.fractionCompleted, 0.25)
        XCTAssertEqual(snapshot.eta, 15)
        XCTAssertNil(ProgressSnapshot(totalBytes: 0, completedBytes: 0, bytesPerSecond: 0, active: [],
                                      concurrency: 1).eta)
    }
}

final class SmallPiecesTests: XCTestCase {
    func testContentRangeParsing() {
        XCTAssertEqual(ContentRange("bytes 100-199/834527"), ContentRange("bytes 100-199/834527"))
        XCTAssertEqual(ContentRange("bytes 100-199/834527")?.total, 834_527)
        XCTAssertEqual(ContentRange("bytes 0-9/*")?.total, nil)
        XCTAssertEqual(ContentRange("bytes 0-9/*")?.start, 0)
        XCTAssertNil(ContentRange("bytes 9-0/10"))
        XCTAssertNil(ContentRange("items 0-9/10"))
        XCTAssertNil(ContentRange(nil))
    }

    func testRedaction() {
        XCTAssertEqual(EventLog.redact("GET /sharing/AbC123?x=AbC123", secrets: ["AbC123", ""]),
                       "GET /sharing/<redacted>?x=<redacted>")
    }

    func testJSONErrorReplyDetection() throws {
        let url = URL(string: "https://nas.test")!
        func response(_ type: String, length: Int?) -> HTTPURLResponse {
            var headers = ["Content-Type": type]
            if let length { headers["Content-Length"] = String(length) }
            return HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        }
        XCTAssertTrue(Downloader.isPossibleErrorReply(response("application/json", length: 40), remaining: 9000))
        XCTAssertFalse(Downloader.isPossibleErrorReply(response("application/json", length: 9000), remaining: 9000))
        XCTAssertTrue(Downloader.isPossibleErrorReply(response("application/json", length: nil), remaining: 9000))
        XCTAssertFalse(Downloader.isPossibleErrorReply(response("application/octet-stream", length: 40), remaining: 9000))
    }

    func testErrorDescriptionsHaveNoSecrets() {
        let errors: [Error] = [DownloadError.sessionExpired, DownloadError.throttled(status: 503), DownloadError.timedOut,
                               DownloadError.changedOnServer, DownloadError.transient("x"),
                               LocalFileError(code: ENOSPC, operation: "write", path: "/d/f")]
        for error in errors { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertTrue(LocalFileError(code: ENOSPC, operation: "write", path: "/d/f").isDiskFull)
    }

    func testPowerAssertionAcquireRelease() {
        let power = PowerAssertion(reason: "SynoShare unit test")
        XCTAssertTrue(power.acquire())
        XCTAssertTrue(power.held)
        XCTAssertTrue(power.acquire(), "idempotent")
        power.release()
        XCTAssertFalse(power.held)
    }

    func testVolumeProbe() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = VolumeProbe(destination: directory)
        XCTAssertTrue(probe.isAvailable())
        try FileManager.default.removeItem(at: directory)
        XCTAssertFalse(probe.isAvailable())
    }

    func testQuickConnectResolveThroughStub() async throws {
        StubProtocol.nas = FakeNAS()
        defer { StubProtocol.nas = nil }
        let endpoint = try await QuickConnect.resolve(try ShareLink(serverID: "AbC12", linkID: "L1"),
                                                      session: StubProtocol.makeSession())
        XCTAssertEqual(endpoint.baseURL.host, "gofile-4162433132.sg3.quickconnect.to")
        XCTAssertEqual(endpoint.relayRegion, "sg3")
    }
}
