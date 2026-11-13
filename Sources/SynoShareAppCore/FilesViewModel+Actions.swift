import Foundation
import SynoShareKit

/// Deep Verify, manifest import, path lists and repair from the Files window.
extension FilesViewModel {
    public var isBusy: Bool { isDeepVerifying || isRepairing }

    public var canRepair: Bool { !selection.isEmpty && !isBusy && destination != nil }

    public var repairButtonTitle: String {
        selectedCount == 1 ? "Repair 1 File" : "Repair \(selectedCount) Files"
    }

    // MARK: Deep Verify

    public func startDeepVerify(restart: Bool = false) {
        guard deepVerifyTask == nil else { return }
        deepVerifyTask = Task {
            await self.deepVerify(restart: restart)
            self.deepVerifyTask = nil
        }
    }

    /// Cancelling keeps what was hashed; the next run resumes (unless restarted).
    public func cancelDeepVerify() { deepVerifyTask?.cancel() }

    public func deepVerify(restart: Bool = false) async {
        guard !isBusy, let destination else { return }
        isDeepVerifying = true
        deepVerifyProgress = nil
        error = nil
        let offline = offline
        let report: @Sendable (DeepVerifyProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.deepVerifyProgress = progress }
        }
        // Detached so hashing runs off the main actor; cancelling this task is forwarded to it.
        let work = Task.detached { try await offline.deepVerify(at: destination, restart: restart, progress: report) }
        do {
            deepVerifyResult = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
        isDeepVerifying = false
        await load()
    }

    // MARK: Manifest

    /// Reads a `sha256sum` / `md5sum` file chosen by the user and records its hashes.
    public func importManifest(from url: URL) async {
        guard let destination else { return }
        error = nil
        do {
            let text = try Self.readText(url)
            let offline = offline
            manifestResult = try await Task.detached { try offline.importManifest(at: destination, text: text) }.value
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
        await load()
    }

    // MARK: Path list

    public func loadPathList(from url: URL) async {
        do {
            pathListText = try Self.readText(url)
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
    }

    /// Adds every listed file to the selection; unmatched lines are reported, not fatal.
    public func applyPathList() {
        let rootNames = Set([destination?.lastPathComponent].compactMap { $0 })
        let result = PathList.select(pathListText, from: entries, rootNames: rootNames)
        select(result.paths)
        pathListResult = result
    }

    // MARK: Repair

    /// Repairs the selection through the main window's engine (pausing and stopping the
    /// main download first), then shows the result and reloads.
    public func repairSelected() async {
        guard canRepair else { return }
        isRepairing = true
        error = nil
        do {
            let summary = try await download.repairFiles(Array(selection).sorted())
            repairSummary = summary
            isRepairResultPresented = true
            await load()
            keepSelected(relPaths: Set(summary.stillBroken.map(\.relPath)))
        } catch {
            self.error = ErrorAdvice.make(for: error)
        }
        isRepairing = false
    }

    /// Reads a user-chosen text file (security-scoped when it came from a file importer).
    static func readText(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
