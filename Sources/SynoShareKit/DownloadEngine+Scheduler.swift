import Foundation

/// The download scheduler: passes over the pending queue with adaptive concurrency,
/// per-file retry with backoff, and pause/resume via cancelling the current pass.
extension DownloadEngine {
    func runJob() async throws {
        _ = try await connectedClient()
        if try !store.isListingComplete { try await listShare(refresh: false) }
        guard !isStopping else { return }
        try reconcileExisting()
        try store.resetInterrupted()
        try checkFreeSpace()
        try createFolders()
        let ticker = startTicker()
        defer { ticker.cancel() }
        try await downloadLoop()
        tick()
    }

    private func downloadLoop() async throws {
        while !isStopping {
            if !volumeAvailable() { pause(.volumeUnavailable) }
            if !pauseReasons.isEmpty {
                await waitUntilResumed()
                continue
            }
            setPhase(.downloading)
            if configuration.preventSleep { power.acquire() }
            let pass = Task { try await self.downloadPass() }
            passTask = pass
            let result = await pass.result
            passTask = nil
            power.release()
            switch result {
            case .success:
                if pauseReasons.isEmpty { return }
            case .failure(let error):
                // Only pause/stop cancel a pass; the loop re-checks both (a pause may already be resumed).
                if error is CancellationError { continue }
                emit(.error(describe(error)))
                note("stopped on error: \(describe(error))")
                throw error
            }
        }
    }

    private func downloadPass() async throws {
        let queue = try store.files(status: .pending)
        try resetMeter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = queue.makeIterator()
            var running = 0
            while true {
                while running < concurrency.current, !Task.isCancelled, let next = iterator.next() {
                    group.addTask { try await self.downloadWithRetry(next) }
                    running += 1
                }
                guard running > 0 else {
                    try Task.checkCancellation()
                    return
                }
                try await group.next()
                running -= 1
            }
        }
    }

    private func resetMeter() throws {
        let files = try store.files(status: .pending, .downloading, .failed, .done, .adopted)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let completed = files.reduce(Int64(0)) { sum, file in
            sum + (file.status.isComplete ? file.size : min(partBytes(file), file.size))
        }
        meter.reset(total: total, completed: completed)
    }

    // MARK: - One file

    private func downloadWithRetry(_ initial: FileRecord) async throws {
        var file = initial
        var attempts = file.attempts
        try store.markDownloading(file.path)
        emit(.fileStarted(path: file.path, size: file.size))
        while true {
            let generation = sessionGeneration
            meter.begin(file.path, size: file.size, already: partBytes(file))
            do {
                let outcome = try await makeDownloader().download(job(for: file))
                meter.end(file.path, credit: outcome == .adopted ? file.size - partBytes(file) : 0)
                try record(outcome, for: file)
                concurrency.recordSuccess()
                return
            } catch {
                meter.end(file.path)
                guard let next = try await handleFailure(error, file: file, attempts: &attempts,
                                                         generation: generation) else { return }
                file = next
            }
        }
    }

    /// Returns the record to try again, or nil when the file is settled (failed / gone).
    private func handleFailure(_ error: Error, file: FileRecord, attempts: inout Int,
                               generation: Int) async throws -> FileRecord? {
        let kind = FailureClassifier.classify(error)
        if kind == .cancelled || Task.isCancelled || !volumeAvailable() {
            if !volumeAvailable() { pause(.volumeUnavailable) }
            try? store.markInterrupted(file.path, bytes: partBytes(file))
            throw CancellationError()
        }
        let message = describe(error)
        attempts += 1
        if kind == .fatal {
            try? store.recordFailure(file.path, attempts: attempts, error: message, final: true)
            throw error
        }
        var current = file
        switch kind {
        case .sessionExpired:
            do {
                try await refreshSession(seenGeneration: generation)
            } catch where FailureClassifier.classify(error) == .fatal {
                throw error
            } catch {
                note("re-login failed: \(describe(error))")
            }
        case .throttled:
            concurrency.recordThrottle()
        case .changedOnServer:
            if let refreshed = try? await refreshListing(file) {
                current = refreshed
                try store.markDownloading(file.path)
            }
        default:
            break
        }
        if configuration.retryPolicy.shouldGiveUp(afterAttempts: attempts) {
            try store.recordFailure(file.path, attempts: attempts, error: message, final: true)
            emit(.fileFailed(path: file.path, message: message))
            note("failed after \(attempts) attempt(s): \(file.relPath): \(message)")
            return nil
        }
        try store.recordFailure(file.path, attempts: attempts, error: message, final: false)
        emit(.fileRetrying(path: file.path, attempt: attempts, message: message))
        note("retry \(attempts) for \(file.relPath): \(message)")
        do {
            try await Task.sleep(for: .seconds(configuration.retryPolicy.delay(afterAttempt: attempts)))
        } catch {
            try? store.markInterrupted(file.path, bytes: partBytes(file))
            throw error
        }
        return current
    }

    private func record(_ outcome: DownloadOutcome, for file: FileRecord) throws {
        let status: FileStatus
        switch outcome {
        case .downloaded:
            status = .done
            try store.markComplete(file.path, status: .done, bytes: file.size)
        case .adopted:
            status = .adopted
            try store.markComplete(file.path, status: .adopted, bytes: file.size, note: Self.adoptedNote)
        case .conflict(let localSize):
            status = .conflict
            try store.markConflict(file.path, note: Self.conflictNote(local: localSize, server: file.size))
        }
        emit(.fileFinished(path: file.path, status: status))
        note("\(status.rawValue): \(file.relPath)")
    }

    private func job(for file: FileRecord) -> DownloadJob {
        DownloadJob(remotePath: file.path, root: destination, localPath: file.localPath, size: file.size,
                    modified: file.modified, replaceExisting: file.replaceExisting)
    }

    private func makeDownloader() throws -> Downloader {
        guard let client else { throw SynoError.unexpectedResponse("download without a session") }
        let meter = meter
        return Downloader(session: session, makeRequest: { path, range in
            try await client.downloadRequest(remotePath: path, range: range)
        }, progress: { path, delta in
            meter.add(path, delta)
        })
    }

    // MARK: - Ticker: progress events and volume checks

    private func startTicker() -> Task<Void, Never> {
        let interval = configuration.tickInterval
        return Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self.tick()
            }
        }
    }

    func tick() {
        let seconds = Double(configuration.tickInterval.components.seconds)
            + Double(configuration.tickInterval.components.attoseconds) / 1e18
        speed.add(bytes: meter.drainTransferred(), over: seconds)
        emit(.progress(meter.snapshot(speed: speed.bytesPerSecond, concurrency: concurrency.current)))
        checkVolume()
    }

    private func checkVolume() {
        let available = volumeAvailable()
        if !available, !pauseReasons.contains(.volumeUnavailable) {
            emit(.warning("Destination volume is unavailable; paused until it returns."))
            pause(.volumeUnavailable)
        } else if available, pauseReasons.contains(.volumeUnavailable) {
            // The old database handle points at the vanished mount: reopen it.
            do {
                store = try StateStore.open(destination: destination)
            } catch {
                emit(.warning("Volume returned but state could not be reopened: \(describe(error))"))
                return
            }
            pauseReasons.remove(.volumeUnavailable)
            note("destination volume available again; resuming")
            wakeIfUnpaused()
        }
    }
}
