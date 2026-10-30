import Darwin
import Foundation

/// A local filesystem failure. `code` is the POSIX errno.
public struct LocalFileError: Error, LocalizedError, Equatable {
    public let code: Int32
    public let operation: String
    public let path: String

    public var errorDescription: String? {
        "\(operation) failed for \(path): \(String(cString: strerror(code)))"
    }

    public var isDiskFull: Bool { code == ENOSPC || code == EDQUOT }
}

/// POSIX file operations that never follow symlinks below the destination
/// and never replace an existing file unless explicitly asked to.
enum SafeFS {
    static let directoryMode: mode_t = 0o755
    static let fileMode: mode_t = 0o644

    /// The real path of an existing folder via `realpath(3)`. Unlike
    /// `URL.resolvingSymlinksInPath()` it keeps `/private` (so `/var/...` resolves correctly).
    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    /// Creates `relative` (slash-separated) under `root`, one component at a time,
    /// refusing any component that is a symlink or not a directory.
    @discardableResult
    static func ensureDirectory(root: URL, relative: String) throws -> URL {
        var current = root
        for component in relative.split(separator: "/").map(String.init) {
            current = current.appending(path: component, directoryHint: .isDirectory)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw LocalFileError(code: ENOTDIR, operation: "use folder", path: current.path) }
                continue
            }
            guard errno == ENOENT else { throw lastError("inspect folder", current) }
            if mkdir(current.path, directoryMode) != 0, errno != EEXIST { throw lastError("create folder", current) }
        }
        return current
    }

    /// Size of a regular file; nil if absent. Throws for symlinks and other non-regular files.
    static func regularFileSize(_ url: URL) throws -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw lastError("inspect file", url)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw LocalFileError(code: EFTYPE, operation: "use file (not a regular file)", path: url.path)
        }
        return Int64(info.st_size)
    }

    /// Opens (creating if needed) a file for writing at `offset`, discarding anything past it.
    static func openForWriting(_ url: URL, at offset: Int64) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard descriptor >= 0 else { throw lastError("open", url) }
        guard ftruncate(descriptor, off_t(offset)) == 0, lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else {
            let error = lastError("truncate", url)
            close(descriptor)
            throw error
        }
        return descriptor
    }

    static func write(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, base + written, buffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LocalFileError(code: errno, operation: "write", path: path)
                }
                written += result
            }
        }
    }

    /// `F_FULLFSYNC` asks the drive itself to flush its cache, which plain `fsync`
    /// does not on macOS. Falls back to `fsync` where the filesystem refuses it.
    static func fullSync(_ descriptor: Int32, path: String) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw LocalFileError(code: errno, operation: "fsync", path: path) }
    }

    static func setModificationDate(_ date: Date, of url: URL) throws {
        let seconds = date.timeIntervalSince1970
        var times = [timespec](repeating: timespec(), count: 2)
        times[0] = timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))
        times[1] = timespec(tv_sec: Int(seconds.rounded(.down)), tv_nsec: 0)
        guard utimensat(AT_FDCWD, url.path, times, AT_SYMLINK_NOFOLLOW) == 0 else { throw lastError("set date", url) }
    }

    /// Atomic rename. With `replacing == false` an existing target is never overwritten
    /// (`RENAME_EXCL`); filesystems without it get an explicit existence check instead.
    static func move(_ source: URL, to target: URL, replacing: Bool) throws {
        if replacing {
            guard rename(source.path, target.path) == 0 else { throw lastError("rename", target) }
            return
        }
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return }
        guard errno == ENOTSUP || errno == EINVAL else { throw lastError("rename", target) }
        guard !exists(target) else {
            throw LocalFileError(code: EEXIST, operation: "rename", path: target.path)
        }
        guard rename(source.path, target.path) == 0 else { throw lastError("rename", target) }
    }

    /// Unlinks a file (never a symlink's target). Missing files are fine.
    static func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw lastError("delete", url) }
    }

    static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    /// True if anything (file, folder or symlink) is at `url`.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func lastError(_ operation: String, _ url: URL) -> LocalFileError {
        LocalFileError(code: errno, operation: operation, path: url.path)
    }
}
