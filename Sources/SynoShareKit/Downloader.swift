import Foundation

/// What to fetch and where to put it.
struct DownloadJob: Sendable {
    let remotePath: String
    /// The destination root and the file's path below it.
    let root: URL
    let localPath: String
    let size: Int64
    let modified: Date?
    /// The user chose Replace for a conflict; otherwise an existing file is never overwritten.
    let replaceExisting: Bool

    var localURL: URL { PathMapper.localURL(destination: root, relative: localPath) }
}

enum DownloadOutcome: Sendable, Equatable {
    /// Finished and renamed into place.
    case downloaded
    /// An untracked local file of the right size was already there (DECISIONS #8: skip, tag).
    case adopted
    /// An untracked local file of a different size is in the way: never overwritten.
    case conflict(localSize: Int64)
}

/// Downloads one file: resume from `.part` with `Range`, stream to disk,
/// `F_FULLFSYNC`, set mtime, then atomic rename into place.
struct Downloader: Sendable {
    let session: URLSession
    /// Builds the download request (from `ShareClient`) for a remote path and optional range.
    let makeRequest: @Sendable (_ remotePath: String, _ range: String?) async throws -> URLRequest
    /// Byte deltas for progress (negative when a `.part` is truncated).
    let progress: @Sendable (_ remotePath: String, _ delta: Int64) -> Void

    /// JSON replies at most this big are treated as possible API errors, not file data.
    static let errorReplyLimit: Int64 = 64 * 1024

    func download(_ job: DownloadJob) async throws -> DownloadOutcome {
        // Re-checked per file: no folder on the way may have become a symlink.
        try SafeFS.ensureDirectory(root: job.root, relative: (job.localPath as NSString).deletingLastPathComponent)
        if let existing = try SafeFS.regularFileSize(job.localURL), !job.replaceExisting {
            return existing == job.size ? .adopted : .conflict(localSize: existing)
        }
        let part = PathMapper.partURL(for: job.localURL)
        var offset = try SafeFS.regularFileSize(part) ?? 0
        if offset > job.size {
            try SafeFS.remove(part)
            offset = 0
        }
        let path = job.remotePath
        let writer = try PartWriter(url: part, offset: offset) { progress(path, $0) }
        defer { writer.close() }
        if offset < job.size {
            try await transfer(job, writer: writer, from: offset)
        }
        guard writer.position == job.size else {
            throw DownloadError.transient("Incomplete: \(writer.position) of \(job.size) bytes.")
        }
        try writer.finish()
        if let modified = job.modified { try SafeFS.setModificationDate(modified, of: part) }
        try SafeFS.move(part, to: job.localURL, replacing: job.replaceExisting)
        SafeFS.syncDirectory(job.localURL.deletingLastPathComponent())
        return .downloaded
    }

    private func transfer(_ job: DownloadJob, writer: PartWriter, from offset: Int64) async throws {
        let request = try await makeRequest(job.remotePath, offset > 0 ? "\(offset)-" : nil)
        let size = job.size
        let result = try await StreamingFetch.run(request, session: session, decide: { response in
            try Self.prepare(response, size: size, offset: offset, writer: writer)
        }, sink: { data in
            try writer.append(data)
            return true
        })
        try Self.check(result, size: size, writer: writer)
    }

    /// Decides from the headers whether the body is file data, and lines the `.part` up with it.
    static func prepare(_ response: HTTPURLResponse, size: Int64, offset: Int64, writer: PartWriter) throws -> Bool {
        if isPossibleErrorReply(response, remaining: size - offset) { return false }
        switch response.statusCode {
        case 206:
            guard let range = ContentRange(response.value(forHTTPHeaderField: "Content-Range")) else {
                throw DownloadError.transient("Partial reply without Content-Range.")
            }
            if let total = range.total, total != size { throw DownloadError.changedOnServer }
            if range.start == offset { return true }
            guard range.start == 0 else { throw DownloadError.transient("Server resumed at an unexpected offset.") }
            try writer.truncate(to: 0)
            return true
        case 200:
            let length = response.expectedContentLength
            if length >= 0, length != size { throw DownloadError.changedOnServer }
            // The server ignored Range: start the file again from byte 0.
            if offset > 0 { try writer.truncate(to: 0) }
            return true
        default:
            return false
        }
    }

    /// Synology reports session errors as a small JSON body with HTTP 200.
    /// A real `.json` file is told apart by its length matching the remaining bytes.
    static func isPossibleErrorReply(_ response: HTTPURLResponse, remaining: Int64) -> Bool {
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.contains("application/json") else { return false }
        let length = response.expectedContentLength
        if length < 0 { return true }
        return length != remaining && length <= errorReplyLimit
    }

    static func check(_ result: FetchResult, size: Int64, writer: PartWriter) throws {
        let status = result.response.statusCode
        if !result.body.isEmpty || isPossibleErrorReply(result.response, remaining: size - writer.position) {
            if let code = ShareClient.errorCode(in: result.body) {
                if FailureClassifier.sessionErrorCodes.contains(code) { throw DownloadError.sessionExpired }
                throw SynoError.api(code: code, context: "download")
            }
            // Not an API error after all: a small JSON file with unknown length.
            if status == 200 || status == 206, Int64(result.body.count) == size - writer.position {
                try writer.append(result.body)
                return
            }
        }
        switch status {
        case 200, 206:
            return
        case 416:
            // Our offset is beyond what the server has: start over from zero.
            try writer.truncate(to: 0)
            throw DownloadError.transient("Range not satisfiable; restarting the file.")
        case 429, 503:
            throw DownloadError.throttled(status: status)
        default:
            throw SynoError.http(status: status, context: "download")
        }
    }
}
