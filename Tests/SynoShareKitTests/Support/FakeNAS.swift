import Foundation
@testable import SynoShareKit

/// Scripted misbehaviour for one download request of a path.
enum Behavior: Equatable {
    case status(Int)
    case timeout
    case ignoreRange
    case rangeNotSatisfiable
    case sessionExpired
    /// Send this many body bytes, then drop the connection.
    case dropAfter(Int)
}

/// What the stub protocol sends back.
struct StubReply {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var dropAfter: Int?
    var error: URLError?

    static func json(_ object: Any, status: Int = 200) -> StubReply {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return StubReply(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func apiError(_ code: Int) -> StubReply { json(["success": false, "error": ["code": code]]) }
}

/// An in-memory Synology share speaking the sharing WebAPI subset the engine uses.
/// Enforces the verified protocol facts (login without X-SYNO-SHARING, JSON-literal params).
final class FakeNAS: @unchecked Sendable {
    let password: String
    let root = "/Share"
    private let lock = NSLock()
    private var files: [String: (data: Data, mtime: Int)] = [:]
    private var folders: Set<String> = ["/Share"]
    private var extraEntries: [String: [[String: Any]]] = [:]
    private var behaviors: [String: [Behavior]] = [:]
    private var sessionValid = false
    private(set) var loginCount = 0
    private(set) var ranges: [String: [String?]] = [:]
    private(set) var listCount = 0

    init(password: String = "secret") { self.password = password }

    // MARK: - Setup

    func addFile(_ path: String, _ data: Data, mtime: Int = 1_700_000_000) {
        lock.withLock {
            files[path] = (data, mtime)
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > root.count {
                folders.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    func addFolder(_ path: String) { _ = lock.withLock { folders.insert(path) } }

    /// A raw list entry (for unsafe names or impossible sizes) under `folder`.
    func addRawEntry(in folder: String, name: String, path: String? = nil, isDir: Bool = false, size: Int64 = 1) {
        lock.withLock {
            extraEntries[folder, default: []].append([
                "name": name, "path": path ?? folder + "/" + name, "isdir": isDir,
                "additional": ["size": size, "time": ["mtime": 1_700_000_000]],
            ])
        }
    }

    func script(_ path: String, _ list: [Behavior]) { lock.withLock { behaviors[path] = list } }
    func expireSession() { lock.withLock { sessionValid = false } }
    func rangesRequested(_ path: String) -> [String?] { lock.withLock { ranges[path] ?? [] } }
    var logins: Int { lock.withLock { loginCount } }

    // MARK: - Routing

    func handle(_ request: URLRequest) -> StubReply {
        guard let url = request.url, let host = url.host else { return StubReply(error: URLError(.badURL)) }
        if host.contains("quickconnect") { return quickConnect(request) }
        guard url.path.hasSuffix("/sharing/webapi/entry.cgi") else { return StubReply(status: 404) }
        var params = Self.params(url.query ?? "")
        params.merge(Self.params(String(decoding: Self.body(of: request), as: UTF8.self))) { $1 }
        return lock.withLock { route(params, request: request) }
    }

    private func route(_ params: [String: String], request: URLRequest) -> StubReply {
        switch params["api"] {
        case "SYNO.Core.Sharing.Login":
            if request.value(forHTTPHeaderField: "X-SYNO-SHARING") != nil { return .apiError(101) }
            guard Self.decode(params["password"]) as? String == password else { return .apiError(1001) }
            loginCount += 1
            sessionValid = true
            return .json(["success": true, "data": [:]])
        case "SYNO.Core.Sharing.Initdata":
            return .json(["success": true, "data": ["Private": ["filename": "Share"]]])
        case "SYNO.FolderSharing.List":
            guard sessionValid else { return .apiError(119) }
            listCount += 1
            return list(folder: Self.decode(params["folder_path"]) as? String ?? "")
        case "SYNO.FolderSharing.Download":
            guard sessionValid else { return .apiError(119) }
            let paths = Self.decode(params["path"]) as? [String] ?? []
            return download(paths.first ?? "", range: request.value(forHTTPHeaderField: "Range"))
        default:
            return .apiError(102)
        }
    }

    private func list(folder: String) -> StubReply {
        let childFolders = folders.filter { ($0 as NSString).deletingLastPathComponent == folder && $0 != folder }
        let childFiles = files.filter { ($0.key as NSString).deletingLastPathComponent == folder }
        var entries: [[String: Any]] = childFolders.map {
            ["name": ($0 as NSString).lastPathComponent, "path": $0, "isdir": true, "additional": ["size": 0]]
        }
        entries += childFiles.map { path, file in
            ["name": (path as NSString).lastPathComponent, "path": path, "isdir": false,
             "additional": ["size": file.data.count, "time": ["mtime": file.mtime]]]
        }
        entries += extraEntries[folder] ?? []
        return .json(["success": true, "data": ["files": entries, "total": entries.count, "offset": 0]])
    }

    private func download(_ path: String, range: String?) -> StubReply {
        ranges[path, default: []].append(range)
        guard let file = files[path] else { return .apiError(408) }
        var queue = behaviors[path] ?? []
        let behavior = queue.isEmpty ? nil : queue.removeFirst()
        behaviors[path] = queue
        switch behavior {
        case .status(let code)?: return StubReply(status: code, headers: ["Content-Type": "text/html"], body: Data("busy".utf8))
        case .timeout?: return StubReply(error: URLError(.timedOut))
        case .rangeNotSatisfiable?: return StubReply(status: 416, headers: ["Content-Type": "text/html"])
        case .sessionExpired?:
            sessionValid = false
            return .apiError(106)
        case .ignoreRange?: return Self.serve(file.data, range: nil, dropAfter: nil)
        case .dropAfter(let count)?: return Self.serve(file.data, range: range, dropAfter: count)
        case nil: return Self.serve(file.data, range: range, dropAfter: nil)
        }
    }

    private static func serve(_ data: Data, range: String?, dropAfter: Int?) -> StubReply {
        var headers = ["Content-Type": "application/octet-stream"]
        guard let range, range.hasPrefix("bytes="), let dash = range.firstIndex(of: "-"),
              let start = Int(range[range.index(range.startIndex, offsetBy: 6)..<dash]) else {
            headers["Content-Length"] = String(data.count)
            return StubReply(status: 200, headers: headers, body: data, dropAfter: dropAfter)
        }
        let endText = range[range.index(after: dash)...]
        let end = min(Int(endText) ?? (data.count - 1), data.count - 1)
        guard start < data.count, start <= end else {
            return StubReply(status: 416, headers: ["Content-Range": "bytes */\(data.count)"])
        }
        headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
        headers["Content-Length"] = String(end - start + 1)
        return StubReply(status: 206, headers: headers, body: data.subdata(in: start..<(end + 1)), dropAfter: dropAfter)
    }

    private func quickConnect(_ request: URLRequest) -> StubReply {
        let body = (try? JSONSerialization.jsonObject(with: Self.body(of: request))) as? [[String: Any]]
        let command = body?.first?["command"] as? String
        if command == "get_server_info" {
            return .json([["errno": 0, "env": ["relay_region": "sg3", "control_host": "usc.quickconnect.to"]]])
        }
        return .json([["errno": 0]])
    }

    // MARK: - Parsing helpers

    static func params(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }

    static func decode(_ literal: String?) -> Any? {
        guard let literal else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
