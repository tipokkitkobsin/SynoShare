import Foundation

/// Talks to one share's sharing WebAPI. Session cookies live only in the
/// ephemeral URLSession; nothing here logs or stores the password.
public actor ShareClient {
    public let link: ShareLink
    public let endpoint: ShareEndpoint
    private let session: URLSession
    public private(set) var rootPath: String?

    static let listPageSize = 1000

    public init(link: ShareLink, endpoint: ShareEndpoint, session: URLSession) {
        self.link = link
        self.endpoint = endpoint
        self.session = session
    }

    /// An ephemeral session: in-memory cookies only, nothing written to disk.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["User-Agent": "SynoShare/0.1"]
        return URLSession(configuration: config)
    }

    private var entryURL: URL { endpoint.baseURL.appending(path: "sharing/webapi/entry.cgi") }

    // MARK: - Login and root

    public func login(password: String) async throws {
        do {
            _ = try await callJSON([
                "api": "SYNO.Core.Sharing.Login", "version": "1", "method": "login",
                "sharing_id": jsonLiteral(link.linkID), "password": jsonLiteral(password),
            ], context: "login", sendsSharingHeader: false)
        } catch SynoError.api(let code, _) where code == 1001 {
            throw SynoError.wrongPassword
        }
    }

    @discardableResult
    public func openRoot() async throws -> String {
        let params = ["api": "SYNO.Core.Sharing.Initdata", "version": "1", "method": "get"]
        let reply: [String: Any]
        do {
            reply = try await callJSON(params, context: "share init")
        } catch SynoError.api(let code, _) where code == 101 {
            // Before login the header makes the NAS answer 101; tolerate either order.
            reply = try await callJSON(params, context: "share init", sendsSharingHeader: false)
        }
        guard let data = reply["data"] as? [String: Any],
              let priv = data["Private"] as? [String: Any],
              let name = priv["filename"] as? String, !name.isEmpty else {
            throw SynoError.unexpectedResponse("share init")
        }
        let root = "/" + name
        rootPath = root
        return root
    }

    // MARK: - Listing

    public func list(folder: String) async throws -> [ShareEntry] {
        var entries: [ShareEntry] = []
        var offset = 0
        while true {
            let reply = try await callWithHeaderFallback([
                "api": "SYNO.FolderSharing.List", "version": "2", "method": "list",
                "offset": String(offset), "limit": String(Self.listPageSize),
                "sort_by": jsonLiteral("name"), "sort_direction": jsonLiteral("ASC"),
                "action": jsonLiteral("enum"), "filetype": jsonLiteral("all"),
                "additional": #"["size","time","type"]"#,
                "folder_path": jsonLiteral(folder), "_sharing_id": jsonLiteral(link.linkID),
            ], context: "list")
            let data = reply["data"] as? [String: Any] ?? [:]
            let files = data["files"] as? [[String: Any]] ?? []
            entries += files.compactMap(Self.entry(from:))
            offset += files.count
            let total = data["total"] as? Int ?? offset
            if files.isEmpty || offset >= total { return entries }
        }
    }

    static func entry(from raw: [String: Any]) -> ShareEntry? {
        guard let name = raw["name"] as? String, let path = raw["path"] as? String else { return nil }
        let extra = raw["additional"] as? [String: Any] ?? [:]
        let size = (extra["size"] as? NSNumber)?.int64Value ?? 0
        let time = extra["time"] as? [String: Any] ?? [:]
        let modified = (time["mtime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let isDir = (raw["isdir"] as? Bool) ?? ((raw["isdir"] as? NSNumber)?.boolValue ?? false)
        return ShareEntry(name: name, path: path, isDirectory: isDir, size: size, modified: modified)
    }

    // MARK: - Download

    /// The request that downloads `remotePath`, optionally from a byte range.
    public func downloadRequest(remotePath: String, range: String? = nil) throws -> URLRequest {
        let pathJSON = try JSONSerialization.data(withJSONObject: [remotePath])
        var components = URLComponents(url: entryURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = FormEncoding.encode([
            "api": "SYNO.FolderSharing.Download", "version": "2", "method": "download",
            "mode": jsonLiteral("download"), "_sharing_id": jsonLiteral(link.linkID),
            "path": String(decoding: pathJSON, as: UTF8.self),
        ])
        guard let url = components?.url else { throw SynoError.unexpectedResponse("download URL") }
        var request = URLRequest(url: url)
        request.setValue(link.linkID, forHTTPHeaderField: "X-SYNO-SHARING")
        if let range { request.setValue("bytes=\(range)", forHTTPHeaderField: "Range") }
        return request
    }

    /// Downloads into memory. For the feasibility probe only (small files).
    public func fetch(remotePath: String, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let request = try downloadRequest(remotePath: remotePath, range: range)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SynoError.unexpectedResponse("download") }
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("application/json") {
            let code = Self.errorCode(in: data) ?? -1
            throw SynoError.api(code: code, context: "download")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SynoError.http(status: http.statusCode, context: "download")
        }
        return (data, http)
    }

    // MARK: - Plumbing

    /// Values must be JSON literals (the API's requestFormat is JSON): a bare
    /// string is rejected with error 120. Login must omit X-SYNO-SHARING,
    /// or the NAS answers 101 (verified 2026-10-30).
    private func callJSON(_ params: [String: String], context: String,
                          sendsSharingHeader: Bool = true) async throws -> [String: Any] {
        var request = URLRequest(url: entryURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if sendsSharingHeader {
            request.setValue(link.linkID, forHTTPHeaderField: "X-SYNO-SHARING")
        }
        request.httpBody = Data(FormEncoding.encode(params).utf8)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SynoError.http(status: http.statusCode, context: context)
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SynoError.unexpectedResponse(context)
        }
        guard reply["success"] as? Bool == true else {
            throw SynoError.api(code: Self.errorCode(in: data) ?? -1, context: context)
        }
        return reply
    }

    /// Tries with X-SYNO-SHARING first, as the web client does after login;
    /// retries once without it if the NAS answers 101.
    private func callWithHeaderFallback(_ params: [String: String], context: String) async throws -> [String: Any] {
        do {
            return try await callJSON(params, context: context)
        } catch SynoError.api(let code, _) where code == 101 {
            return try await callJSON(params, context: context, sendsSharingHeader: false)
        }
    }

    static func errorCode(in data: Data) -> Int? {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = reply["error"] as? [String: Any] else { return nil }
        return error["code"] as? Int
    }
}
