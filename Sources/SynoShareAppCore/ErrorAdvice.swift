import Foundation
import SynoShareKit

/// Which control an error belongs next to.
public enum ErrorField: Sendable, Equatable {
    case shareURL
    case password
    case destination
    case general
}

/// A user-facing error: what went wrong, where, and what to do about it.
public struct ErrorAdvice: Sendable, Equatable {
    public let field: ErrorField
    public let message: String
    public let recovery: String

    public init(field: ErrorField, message: String, recovery: String) {
        self.field = field
        self.message = message
        self.recovery = recovery
    }

    public static let driveUnplugged = ErrorAdvice(
        field: .destination, message: "The destination drive is not available.",
        recovery: "Reconnect the drive. Downloading continues automatically from where it stopped.")

    public static let missingDestination = ErrorAdvice(
        field: .destination, message: "Choose a destination folder.",
        recovery: "Click Choose… and pick a folder on a drive with enough free space.")

    /// Maps engine and system errors to advice. Messages carry no secrets
    /// (the engine already redacts link ids; the password is never in an error).
    public static func make(for error: Error) -> ErrorAdvice {
        switch error {
        case let error as AdviceError: return error.advice
        case let error as SynoError: return advice(for: error)
        case is MissingPasswordError:
            return ErrorAdvice(field: .password, message: "Enter the share password.",
                               recovery: "The password is the one given with the share link.")
        case let error as PreflightError:
            return ErrorAdvice(field: .destination, message: error.localizedDescription,
                               recovery: "Free up space on the drive or choose a larger destination.")
        case let error as LocalFileError where error.isDiskFull:
            return ErrorAdvice(field: .destination, message: "The destination drive is full.",
                               recovery: "Free up space, then click Download All to continue.")
        case let error as StateStoreError where error.message.contains("different share link"):
            return ErrorAdvice(field: .destination, message: error.message,
                               recovery: "Choose an empty folder for this share, or the folder used for it before.")
        case let error as URLError: return advice(for: error)
        default:
            return ErrorAdvice(field: .general, message: error.localizedDescription,
                               recovery: "Try again. Progress is saved, so nothing already downloaded is lost.")
        }
    }

    private static func advice(for error: SynoError) -> ErrorAdvice {
        switch error {
        case .invalidLink:
            return ErrorAdvice(field: .shareURL, message: "This is not a Synology share link.",
                               recovery: "Paste the full link, e.g. https://gofile.me/<server>/<link>.")
        case .wrongPassword:
            return ErrorAdvice(field: .password, message: "Wrong share password.",
                               recovery: "Check the password (it is case-sensitive) and click Connect again.")
        case .serverNotFound:
            return unreachable(error.localizedDescription)
        default:
            return ErrorAdvice(field: .general, message: error.localizedDescription,
                               recovery: "Try again later. The NAS may be busy or the link may have expired.")
        }
    }

    private static func advice(for error: URLError) -> ErrorAdvice {
        let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                           .cannotConnectToHost, .dnsLookupFailed, .timedOut]
        guard offline.contains(error.code) else {
            return ErrorAdvice(field: .general, message: error.localizedDescription,
                               recovery: "Try again. Progress is saved.")
        }
        return unreachable(error.localizedDescription)
    }

    private static func unreachable(_ detail: String) -> ErrorAdvice {
        ErrorAdvice(field: .shareURL, message: "The NAS could not be reached. \(detail)",
                    recovery: "Check your internet connection. The NAS may be offline; try again later.")
    }
}
