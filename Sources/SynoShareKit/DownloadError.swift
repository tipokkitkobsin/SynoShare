import Foundation

/// Why one download attempt failed. Messages contain no secrets.
public enum DownloadError: Error, LocalizedError, Equatable {
    /// The NAS answered with a session error (105/106/119) instead of data.
    case sessionExpired
    /// 429 or 503: the server or relay asks us to slow down.
    case throttled(status: Int)
    case timedOut
    /// The server reports a different size than the listing: the file changed.
    case changedOnServer
    /// Network or server trouble worth retrying.
    case transient(String)

    public var errorDescription: String? {
        switch self {
        case .sessionExpired: return "Session expired."
        case .throttled(let status): return "Server busy (HTTP \(status))."
        case .timedOut: return "Timed out."
        case .changedOnServer: return "File changed on the server since listing."
        case .transient(let detail): return detail
        }
    }
}

/// What the scheduler should do about an error.
enum FailureKind: Equatable {
    case sessionExpired
    case throttled
    case changedOnServer
    case retryable
    /// Stop the whole job (wrong password, disk full).
    case fatal
    case cancelled
}

enum FailureClassifier {
    static let sessionErrorCodes: Set<Int> = [105, 106, 119]

    static func classify(_ error: Error) -> FailureKind {
        if error is CancellationError { return .cancelled }
        switch error {
        case let error as DownloadError:
            switch error {
            case .sessionExpired: return .sessionExpired
            case .throttled, .timedOut: return .throttled
            case .changedOnServer: return .changedOnServer
            case .transient: return .retryable
            }
        case let error as SynoError:
            if error == .wrongPassword { return .fatal }
            if case .api(let code, _) = error, sessionErrorCodes.contains(code) { return .sessionExpired }
            if case .http(let status, _) = error, status == 429 || status == 503 { return .throttled }
            return .retryable
        case let error as LocalFileError:
            return error.isDiskFull ? .fatal : .retryable
        case let error as URLError:
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .throttled
            default: return .retryable
            }
        default:
            return .retryable
        }
    }
}
