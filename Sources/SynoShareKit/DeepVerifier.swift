import Foundation

/// Progress of a Deep Verify run, reported after each file.
public struct DeepVerifyProgress: Sendable, Equatable {
    public let filesDone: Int
    public let filesTotal: Int
    public let relPath: String
}

public struct DeepVerifyResult: Sendable, Equatable {
    /// Files examined in this run (skipped ones excluded).
    public let checked: Int
    /// Files already hashed by an interrupted run that this one resumed.
    public let skipped: Int
    /// Files that match their reference, or had none and got a baseline.
    public let ok: Int
    /// Of `ok`: files that had no hash before and now have one.
    public let baselined: Int
    public let problems: [FileIssue]
    /// The run stopped early; the next run resumes where this one stopped.
    public let cancelled: Bool
}

/// Deep Verify (docs/REPAIR_PLAN.md, R2): re-reads every completed file from disk.
/// Size first (as `Verifier`), then SHA-256 (plus MD5 when a manifest gives one).
/// No reference → the hash becomes the baseline. A reference that does not match →
/// `checksumMismatch` (conflict, never overwritten).
///
/// Resumable: the start time is stored; a later run skips files hashed since then.
public enum DeepVerifier {
    private enum Outcome {
        case ok(baselined: Bool)
        case problem(FileIssue)
    }

    public static func run(store: StateStore, restart: Bool = false,
                           isCancelled: () -> Bool = { false },
                           progress: (DeepVerifyProgress) -> Void = { _ in }) throws -> DeepVerifyResult {
        let resumed = restart ? nil : try store.deepVerifyStartedAt()
        let started = resumed ?? Date()
        try store.setDeepVerifyStartedAt(started)
        let complete = try store.files(status: .done, .adopted)
        let queue = complete.filter { file in file.hashedAt.map { $0 < started } ?? true }
        var outcomes: [Outcome] = []
        for file in queue {
            guard !isCancelled() else { break }
            do {
                outcomes.append(try check(file, store: store, isCancelled: isCancelled))
            } catch is CancellationError {
                break
            }
            progress(DeepVerifyProgress(filesDone: outcomes.count, filesTotal: queue.count, relPath: file.relPath))
        }
        let cancelled = outcomes.count < queue.count
        if !cancelled { try store.setDeepVerifyStartedAt(nil) }
        return summary(outcomes, skipped: complete.count - queue.count, cancelled: cancelled)
    }

    private static func check(_ file: FileRecord, store: StateStore, isCancelled: () -> Bool) throws -> Outcome {
        if let problem = try Verifier.checkSize(file, store: store) { return .problem(problem) }
        let url = PathMapper.localURL(destination: store.destination, relative: file.localPath)
        let algorithms: Set<HashAlgorithm> = [.sha256, file.expectedHash?.algorithm ?? .sha256]
        let digests = try FileHasher.digests(of: url, algorithms: algorithms, isCancelled: isCancelled)
        guard let sha256 = digests[.sha256] else { throw StateStoreError("SHA-256 missing for \(file.relPath)") }
        if let mismatch = mismatchedAlgorithm(file, digests: digests) {
            try store.markChecksumMismatch(file.path, algorithm: mismatch)
            return .problem(FileIssue(relPath: file.relPath, message: "checksum mismatch (\(mismatch.rawValue))"))
        }
        try store.recordHash(file.path, sha256: sha256, at: Date())
        return .ok(baselined: file.sha256 == nil && file.expectedHash == nil)
    }

    /// The manifest hash wins over the recorded download hash.
    static func mismatchedAlgorithm(_ file: FileRecord, digests: [HashAlgorithm: String]) -> HashAlgorithm? {
        if let expected = file.expectedHash {
            return digests[expected.algorithm] == expected.hex ? nil : expected.algorithm
        }
        if let recorded = file.sha256, recorded != digests[.sha256] { return .sha256 }
        return nil
    }

    private static func summary(_ outcomes: [Outcome], skipped: Int, cancelled: Bool) -> DeepVerifyResult {
        var problems: [FileIssue] = []
        var baselined = 0
        for outcome in outcomes {
            switch outcome {
            case .ok(let isBaseline): baselined += isBaseline ? 1 : 0
            case .problem(let issue): problems.append(issue)
            }
        }
        return DeepVerifyResult(checked: outcomes.count, skipped: skipped, ok: outcomes.count - problems.count,
                                baselined: baselined, problems: problems, cancelled: cancelled)
    }
}
