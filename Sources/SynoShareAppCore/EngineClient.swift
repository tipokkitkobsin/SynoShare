import Foundation
import SynoShareKit

/// The slice of `DownloadEngine` the app drives. A protocol so the view model
/// can be tested without a network or a NAS.
public protocol EngineControlling: Sendable {
    var events: AsyncStream<EngineEvent> { get }
    func list(refresh: Bool) async throws -> Report
    func run() async throws -> Report
    func retryFailed() async throws -> Report
    func pause() async
    func resume() async
    func stop() async
    func shutdown() async
    func report() async throws -> Report
    func verify() async throws -> VerificationResult
    func resolveConflict(path: String, resolution: ConflictResolution) async throws
    func conflicts() async throws -> [ConflictItem]
}

extension DownloadEngine: EngineControlling {
    public func conflicts() async throws -> [ConflictItem] {
        try files(status: .conflict, .changedOnServer).map(ConflictItem.init(record:))
    }
}

/// A `conflict` or `changed_on_server` file awaiting Replace / Keep both.
public struct ConflictItem: Sendable, Equatable, Identifiable {
    /// Remote path, the key `resolveConflict` needs.
    public let path: String
    public let relPath: String
    public let detail: String
    public var id: String { path }

    public init(path: String, relPath: String, detail: String) {
        self.path = path
        self.relPath = relPath
        self.detail = detail
    }

    public init(record: FileRecord) {
        let reason = record.status == .changedOnServer ? "Changed on the server" : "Local file differs in size"
        self.init(path: record.path, relPath: record.relPath,
                  detail: [reason, record.note].compactMap { $0 }.joined(separator: " — "))
    }
}

/// Reads a destination's state database without a password or network, so the app
/// can show progress made by the CLI (or a previous app session).
public protocol OfflineJobReading: Sendable {
    func hasState(at destination: URL) -> Bool
    func report(at destination: URL) throws -> Report
    func conflicts(at destination: URL) throws -> [ConflictItem]
    func verify(at destination: URL) throws -> VerificationResult
    func resolveConflict(at destination: URL, path: String, resolution: ConflictResolution) throws
}

public struct OfflineJobReader: OfflineJobReading {
    public init() {}

    public func hasState(at destination: URL) -> Bool {
        let file = StateStore.stateDirectory(for: destination).appending(path: StateStore.databaseName)
        return FileManager.default.fileExists(atPath: file.path)
    }

    public func report(at destination: URL) throws -> Report {
        try DownloadEngine.report(destination: destination)
    }

    public func conflicts(at destination: URL) throws -> [ConflictItem] {
        try StateStore.open(destination: destination, create: false)
            .files(status: .conflict, .changedOnServer).map(ConflictItem.init(record:))
    }

    public func verify(at destination: URL) throws -> VerificationResult {
        try DownloadEngine.verify(destination: destination)
    }

    public func resolveConflict(at destination: URL, path: String, resolution: ConflictResolution) throws {
        try StateStore.open(destination: destination, create: false).resolveConflict(path, resolution)
    }
}

/// Holds the share password in memory only, readable from the engine's actor.
public final class PasswordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    public init() {}

    public func set(_ password: String) { lock.withLock { value = password } }

    public func get() -> String { lock.withLock { value } }
}

/// Thrown by the password provider when the field is empty.
public struct MissingPasswordError: Error, LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { "Enter the share password." }
}

/// Builds engines; replaced in tests.
public typealias EngineFactory = @Sendable (EngineConfiguration, @escaping PasswordProvider) throws -> any EngineControlling

public enum Engines {
    public static let live: EngineFactory = { configuration, provider in
        try DownloadEngine(configuration: configuration, passwordProvider: provider)
    }
}
