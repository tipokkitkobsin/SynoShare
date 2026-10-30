import Foundation

/// Errors with user-meaningful messages. Messages never contain the password or cookies.
public enum SynoError: Error, LocalizedError, Equatable {
    case invalidLink
    case serverNotFound(String)
    case wrongPassword
    case api(code: Int, context: String)
    case http(status: Int, context: String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "Not a Synology share link. Expected https://gofile.me/<server>/<link>."
        case .serverNotFound(let detail):
            return "QuickConnect could not locate the server (\(detail))."
        case .wrongPassword:
            return "Wrong share password."
        case .api(let code, let context):
            return "Synology API error \(code) during \(context)\(Self.hint(for: code))."
        case .http(let status, let context):
            return "HTTP \(status) during \(context)."
        case .unexpectedResponse(let context):
            return "Unexpected server response during \(context)."
        }
    }

    private static func hint(for code: Int) -> String {
        switch code {
        case 101: return " (invalid request parameters)"
        case 120: return " (invalid parameter type)"
        case 105, 106, 119: return " (session missing or expired)"
        case 126: return " (permission denied by the share)"
        case 407, 408: return " (no such file or folder)"
        default: return ""
        }
    }
}

/// A Synology folder-share link: QuickConnect server id plus share (link) id.
public struct ShareLink: Sendable, Equatable {
    public let serverID: String
    public let linkID: String

    public init(serverID: String, linkID: String) throws {
        guard Self.isAlphanumeric(serverID), Self.isAlphanumeric(linkID) else { throw SynoError.invalidLink }
        self.serverID = serverID
        self.linkID = linkID
    }

    /// Accepts `gofile.me/<server>/<link>`, `quickconnect.to/<server>/<link>`
    /// and `<server>.quickconnect.to/sharing/<link>`.
    public init(parsing raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host?.lowercased() else { throw SynoError.invalidLink }
        let parts = url.path.split(separator: "/").map(String.init)

        let isBareHost = host == "gofile.me" || host.hasSuffix(".gofile.me")
            || ["quickconnect.to", "quickconnect.cn"].contains(host)
        let isServerSubdomain = host.hasSuffix(".quickconnect.to") || host.hasSuffix(".quickconnect.cn")

        if isBareHost, parts.count == 2, parts[0] != "sharing" {
            try self.init(serverID: parts[0], linkID: parts[1])
        } else if isServerSubdomain, parts.count == 2, parts[0] == "sharing",
                  let sub = host.split(separator: ".").first {
            try self.init(serverID: String(sub), linkID: parts[1])
        } else {
            throw SynoError.invalidLink
        }
    }

    private static func isAlphanumeric(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }
}

/// One file or folder as listed by SYNO.FolderSharing.List.
public struct ShareEntry: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// application/x-www-form-urlencoded body, keys sorted for stable output.
enum FormEncoding {
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encode(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// Synology WebAPI expects many parameters as JSON literals, e.g. "\"name\"".
func jsonLiteral(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data()
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
}
