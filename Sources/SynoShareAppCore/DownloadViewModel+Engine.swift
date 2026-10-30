import Foundation
import SynoShareKit

/// Identifies the engine configuration; a change means a new engine.
struct EngineKey: Equatable {
    let serverID: String
    let linkID: String
    let destinationPath: String
    let preventSleep: Bool
}

extension DownloadViewModel {
    // MARK: Running operations

    func perform(_ kind: EngineOperation,
                 _ body: @escaping @Sendable (any EngineControlling) async throws -> Report) async {
        guard operation == nil, !isVerifying else { return }
        error = nil
        statusMessage = nil
        let engine: any EngineControlling
        do {
            engine = try await prepareEngine()
        } catch {
            self.error = ErrorAdvice.make(for: error)
            return
        }
        operation = kind
        savedPasswordThisRun = false
        listing = nil
        do {
            report = try await body(engine)
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
        operation = nil
        progress = nil
        await refreshState()
    }

    /// Validates the inputs and returns an engine for them, reusing the current one if they did not change.
    func prepareEngine() async throws -> any EngineControlling {
        let link = try ShareLink(parsing: shareURL)
        guard let destination else { throw AdviceError(.missingDestination) }
        guard FileManager.default.fileExists(atPath: destination.path) else { throw AdviceError(.driveUnplugged) }
        guard !password.isEmpty else { throw MissingPasswordError() }
        let key = EngineKey(serverID: link.serverID, linkID: link.linkID,
                            destinationPath: destination.path, preventSleep: preventSleep)
        if let engine, engineKey == key { return engine }
        await disposeEngine()
        var configuration = EngineConfiguration(link: link, destination: destination)
        configuration.preventSleep = preventSleep
        let box = passwordBox
        let created = try makeEngine(configuration) {
            let password = box.get()
            guard !password.isEmpty else { throw MissingPasswordError() }
            return password
        }
        engine = created
        engineKey = key
        let events = created.events
        eventTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        return created
    }

    func disposeEngine() async {
        guard let engine else { return }
        await engine.shutdown()
        eventTask?.cancel()
        self.engine = nil
        engineKey = nil
        phase = .idle
    }

    // MARK: Events

    func handle(_ event: EngineEvent) {
        switch event {
        case .phase(let newPhase):
            phase = newPhase
            if [.listing, .checkingSpace, .downloading].contains(newPhase) { passwordAccepted() }
        case .listing(let folders, let files):
            listing = ListingProgress(folders: folders, files: files)
        case .progress(let snapshot):
            progress = snapshot
        case .fileStarted:
            break
        case .fileFinished, .fileFailed:
            refreshSoon()
        case .fileRetrying(let path, let attempt, let message):
            statusMessage = "Retrying \(Formatting.fileName(path)) (attempt \(attempt)): \(message)"
        case .warning(let message):
            statusMessage = message
        case .error(let message):
            statusMessage = message
        }
    }

    /// Re-reads the report at most every `refreshInterval` while files finish.
    func refreshSoon() {
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= refreshInterval else { return }
        lastRefresh = now
        Task { await refreshState() }
    }

    /// Reloads report and conflicts from the engine, or offline from the destination.
    func refreshState() async {
        do {
            if let engine {
                report = try await engine.report()
                conflicts = try await engine.conflicts()
            } else {
                try await readOffline()
            }
        } catch {
            statusMessage = "Could not read download state: \(error.localizedDescription)"
        }
    }

    func loadOfflineState() async {
        guard engine == nil || engineKey?.destinationPath != destination?.path else {
            await refreshState()
            return
        }
        await disposeEngine()
        do {
            try await readOffline()
            if report != nil { statusMessage = "Showing saved progress. Click Download All to continue." }
        } catch {
            report = nil
            conflicts = []
            statusMessage = "Could not read saved progress: \(error.localizedDescription)"
        }
    }

    private func readOffline() async throws {
        guard let destination, offline.hasState(at: destination) else {
            report = nil
            conflicts = []
            return
        }
        let offline = offline
        let (newReport, newConflicts) = try await Task.detached {
            (try offline.report(at: destination), try offline.conflicts(at: destination))
        }.value
        report = newReport
        conflicts = newConflicts
    }

    // MARK: Keychain

    var keychainAccount: String? {
        (try? ShareLink(parsing: shareURL)).map { "\($0.serverID)/\($0.linkID)" }
    }

    func restoreSavedPassword() {
        guard let account = keychainAccount else { return }
        do {
            if let saved = try passwordStore.password(for: account) {
                password = saved
                rememberPassword = true
            }
        } catch {
            statusMessage = "Could not read the saved password: \(error.localizedDescription)"
        }
    }

    /// Login succeeded: save the password if the user asked to.
    func passwordAccepted() {
        guard rememberPassword, !savedPasswordThisRun, let account = keychainAccount else { return }
        savedPasswordThisRun = true
        do {
            try passwordStore.save(password, for: account)
        } catch {
            statusMessage = "Could not save the password: \(error.localizedDescription)"
        }
    }

    func forgetSavedPassword() {
        guard let account = keychainAccount else { return }
        do {
            try passwordStore.delete(account: account)
        } catch {
            statusMessage = "Could not remove the saved password: \(error.localizedDescription)"
        }
    }
}

/// Carries ready-made advice through `throws`.
struct AdviceError: Error {
    let advice: ErrorAdvice
    init(_ advice: ErrorAdvice) { self.advice = advice }
}
