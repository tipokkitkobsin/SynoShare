import Foundation
import IOKit.pwr_mgt

/// Prevents idle system sleep while held (DECISIONS #9). Lid-close sleep cannot be prevented.
public final class PowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false
    private let reason: String

    public init(reason: String = "SynoShare is downloading") { self.reason = reason }

    deinit { release() }

    public var held: Bool { lock.withLock { isHeld } }

    @discardableResult
    public func acquire() -> Bool {
        lock.withLock {
            guard !isHeld else { return true }
            var identifier: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason as CFString, &identifier)
            guard result == kIOReturnSuccess else { return false }
            assertionID = identifier
            isHeld = true
            return true
        }
    }

    public func release() {
        lock.withLock {
            guard isHeld else { return }
            IOPMAssertionRelease(assertionID)
            isHeld = false
        }
    }
}

/// Tells whether the destination volume is still mounted (DECISIONS #9).
///
/// Polls instead of listening for `NSWorkspace.didUnmountNotification`: polling works
/// in a CLI without a run loop and cannot miss an event while the process is busy.
public struct VolumeProbe: Sendable {
    public let destination: URL
    private let expectedVolume: String?

    public init(destination: URL) {
        self.destination = destination
        expectedVolume = Self.volumeIdentity(of: destination)
    }

    /// The destination exists, is a folder, and lives on the same volume as at start.
    public func isAvailable() -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard let expectedVolume else { return true }
        return Self.volumeIdentity(of: destination) == expectedVolume
    }

    static func volumeIdentity(of url: URL) -> String? {
        let fresh = URL(filePath: url.path, directoryHint: .isDirectory)
        let values = try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        return values?.volumeUUIDString ?? values?.volume?.path
    }
}
