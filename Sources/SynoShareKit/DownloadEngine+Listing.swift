import Foundation

/// Session handling, listing and reconciliation with files already on disk.
extension DownloadEngine {
    // MARK: - Session

    func connectedClient() async throws -> ShareClient {
        if let client { return client }
        setPhase(.connecting)
        let endpoint = try await configuration.resolveEndpoint(configuration.link, session)
        let newClient = ShareClient(link: configuration.link, endpoint: endpoint, session: session)
        try await login(newClient)
        client = newClient
        return newClient
    }

    private func login(_ client: ShareClient) async throws {
        let password = try await passwordProvider()
        try await client.login(password: password)
        note("login OK")
    }

    /// Re-login after a session error. Concurrent callers that saw the same session
    /// share one login; callers whose session was already renewed return at once.
    func refreshSession(seenGeneration: Int) async throws {
        guard sessionGeneration == seenGeneration else { return }
        if let reloginTask {
            try await reloginTask.value
            return
        }
        guard let client else { throw SynoError.unexpectedResponse("re-login without a session") }
        note("session expired; logging in again")
        let task = Task { try await self.login(client) }
        reloginTask = task
        do {
            try await task.value
            sessionGeneration += 1
            reloginTask = nil
        } catch {
            reloginTask = nil
            throw error
        }
    }

    /// Runs an API call; on session expiry logs in again once and repeats it.
    func withSession<T: Sendable>(_ operation: @Sendable (ShareClient) async throws -> T) async throws -> T {
        let client = try await connectedClient()
        let generation = sessionGeneration
        do {
            return try await operation(client)
        } catch where FailureClassifier.classify(error) == .sessionExpired {
            try await refreshSession(seenGeneration: generation)
            return try await operation(client)
        }
    }

    /// Retries listing calls with the same backoff as downloads; fatal errors pass through.
    func retrying<T: Sendable>(_ context: String, _ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                let kind = FailureClassifier.classify(error)
                attempt += 1
                if kind == .fatal || kind == .cancelled || configuration.retryPolicy.shouldGiveUp(afterAttempts: attempt) {
                    throw error
                }
                note("\(context) failed (attempt \(attempt)): \(describe(error))")
                try await Task.sleep(for: .seconds(configuration.retryPolicy.delay(afterAttempt: attempt)))
            }
        }
    }

    // MARK: - Listing

    func listShare(refresh: Bool) async throws {
        _ = try await connectedClient()
        setPhase(.listing)
        let root = try await retrying("share init") { try await self.withSession { try await $0.openRoot() } }
        try store.setRoot(root)
        if refresh { try store.resetListing() }
        var listed = 0
        while !isStopping, let folder = try store.nextUnlistedFolder() {
            try Task.checkCancellation()
            let path = folder.path
            let entries = try await retrying("list") { try await self.withSession { try await $0.list(folder: path) } }
            let parentRel = path == root ? "" : String(path.dropFirst(root.count + 1))
            let mapped = PathMapper.mapChildren(of: path, parentRel: parentRel, parentLocal: folder.localPath,
                                                entries: entries, existing: try store.childLocalPaths(of: path))
            for skipped in mapped where skipped.localPath == nil {
                emit(.warning("Skipped unsafe name: \(skipped.relPath)"))
                note("skipped unsafe name: \(skipped.relPath)")
            }
            for previous in try store.applyListing(folder: path, entries: mapped) {
                discardStalePart(previous)
            }
            listed += 1
            emit(.listing(foldersListed: listed, filesKnown: try store.fileCount()))
        }
        note("listing pass finished: \(listed) folder(s) listed")
    }

    /// DECISIONS #8: a `.part` whose source changed is discarded and the file restarts.
    func discardStalePart(_ previous: FileRecord) {
        note("changed on server: \(previous.relPath) (was \(previous.status.rawValue))")
        guard previous.status.needsDownload else { return }
        try? SafeFS.remove(PathMapper.partURL(for: localURL(previous)))
    }

    /// Re-reads one file's listing after the server reported a different size mid-download.
    func refreshListing(_ file: FileRecord) async throws -> FileRecord? {
        let parent = file.parent
        let entries = try await withSession { try await $0.list(folder: parent) }
        guard let entry = entries.first(where: { $0.path == file.path && !$0.isDirectory }) else { return nil }
        try store.updateListing(file.path, size: entry.size, mtime: StateStore.seconds(entry.modified))
        discardStalePart(file)
        return try store.file(file.path)
    }

    // MARK: - Reconcile with the destination

    /// DECISIONS #8 for files that are on disk but not yet tracked as complete:
    /// same size → `adopted (size-only)`; different size → `conflict`, never overwritten.
    func reconcileExisting() throws {
        for file in try store.files(status: .pending, .failed) where !file.replaceExisting {
            let size: Int64?
            do {
                size = try SafeFS.regularFileSize(localURL(file))
            } catch {
                try store.markConflict(file.path, note: "local path is not a regular file")
                continue
            }
            guard let size else { continue }
            if size == file.size {
                try store.markComplete(file.path, status: .adopted, bytes: size, note: Self.adoptedNote)
            } else {
                try store.markConflict(file.path, note: Self.conflictNote(local: size, server: file.size))
            }
        }
    }

    static let adoptedNote = "adopted (size-only)"

    static func conflictNote(local: Int64, server: Int64) -> String {
        "local file has \(local) bytes, server has \(server)"
    }

    /// Mirrors the folder tree (including empty folders) before downloading.
    func createFolders() throws {
        for folder in try store.folders() where !folder.localPath.isEmpty {
            try SafeFS.ensureDirectory(root: destination, relative: folder.localPath)
        }
    }

    func checkFreeSpace() throws {
        setPhase(.checkingSpace)
        let required = try Preflight.remainingBytes(store: store)
        let available = try Preflight.availableBytes(at: destination)
        note("preflight: need \(required) bytes, \(available) available")
        try Preflight.check(required: required, available: available)
    }
}
