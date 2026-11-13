import CryptoKit
import Darwin
import Foundation

/// A checksum algorithm the state DB records or a manifest supplies.
public enum HashAlgorithm: String, Sendable, CaseIterable, Codable {
    case sha256
    /// Only for comparing against `md5sum` manifests; never recorded on download.
    case md5

    /// Length of the lowercase hex digest.
    public var hexLength: Int {
        switch self {
        case .sha256: return 64
        case .md5: return 32
        }
    }

    /// The algorithm whose hex digest has this length, if any.
    public init?(hexLength: Int) {
        guard let match = Self.allCases.first(where: { $0.hexLength == hexLength }) else { return nil }
        self = match
    }
}

/// A reference checksum (from a manifest) a file must match.
public struct ExpectedHash: Sendable, Equatable {
    public let algorithm: HashAlgorithm
    /// Lowercase hex.
    public let hex: String

    public init(algorithm: HashAlgorithm, hex: String) {
        self.algorithm = algorithm
        self.hex = hex.lowercased()
    }
}

/// Incremental hashing for one algorithm.
struct StreamingDigest {
    private var sha256 = SHA256()
    private var md5 = Insecure.MD5()
    let algorithm: HashAlgorithm

    init(_ algorithm: HashAlgorithm) { self.algorithm = algorithm }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        switch algorithm {
        case .sha256: sha256.update(bufferPointer: bytes)
        case .md5: md5.update(bufferPointer: bytes)
        }
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    func hex() -> String {
        switch algorithm {
        case .sha256: return Self.hex(sha256.finalize())
        case .md5: return Self.hex(md5.finalize())
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads files from disk (never through a symlink) and hashes them in chunks.
enum FileHasher {
    static let chunkSize = 1 << 20

    /// Hex digests of `url`, reading at most `limit` bytes. `isCancelled` is checked
    /// between chunks; a cancelled read throws `CancellationError`.
    static func digests(of url: URL, algorithms: Set<HashAlgorithm>, limit: Int64? = nil,
                        isCancelled: () -> Bool = { false }) throws -> [HashAlgorithm: String] {
        var states = algorithms.map(StreamingDigest.init)
        try read(url, limit: limit, isCancelled: isCancelled) { chunk in
            for index in states.indices { states[index].update(chunk) }
        }
        return Dictionary(uniqueKeysWithValues: states.map { ($0.algorithm, $0.hex()) })
    }

    /// Feeds the file's bytes (up to `limit`) to `consume`, one chunk at a time.
    static func read(_ url: URL, limit: Int64? = nil, isCancelled: () -> Bool = { false },
                     consume: (UnsafeRawBufferPointer) -> Void) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalFileError(code: errno, operation: "open for hashing", path: url.path) }
        defer { close(descriptor) }
        var remaining = limit ?? Int64.max
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            let wanted = Int(min(Int64(chunkSize), remaining))
            let count = Darwin.read(descriptor, buffer.baseAddress, wanted)
            if count < 0 {
                if errno == EINTR { continue }
                throw LocalFileError(code: errno, operation: "read", path: url.path)
            }
            if count == 0 { return }
            consume(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            remaining -= Int64(count)
        }
    }
}
