import Foundation
import SQLite3

/// A value bound to or read from SQLite. Only the types the state DB uses.
enum SQLValue: Equatable, Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    init(_ value: Int64?) { self = value.map { .integer($0) } ?? .null }
    init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// One result row, addressed by column name.
struct SQLRow {
    let columns: [String: SQLValue]

    func int(_ name: String) -> Int64? {
        switch columns[name] {
        case .integer(let value)?: return value
        case .real(let value)?: return Int64(value)
        default: return nil
        }
    }

    func text(_ name: String) -> String? {
        if case .text(let value)? = columns[name] { return value }
        return nil
    }

    func date(_ name: String) -> Date? {
        switch columns[name] {
        case .real(let value)?: return Date(timeIntervalSince1970: value)
        case .integer(let value)?: return Date(timeIntervalSince1970: Double(value))
        default: return nil
        }
    }
}

public struct StateStoreError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// `SQLITE_TRANSIENT` is a C macro Swift cannot import: it tells SQLite to copy bound text.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper over the system libsqlite3 (no third-party dependency).
/// Every call is serialised by a recursive lock so the store is safe to share.
final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSRecursiveLock()

    init(path: String) throws {
        var db: OpaquePointer?
        // NOFOLLOW: never open the state DB through a symlink.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
            sqlite3_close_v2(db)
            throw StateStoreError("Cannot open state database: \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        try locked {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? lastError
                sqlite3_free(message)
                throw StateStoreError("SQLite: \(text)")
            }
        }
    }

    @discardableResult
    func query(_ sql: String, _ arguments: [SQLValue] = []) throws -> [SQLRow] {
        try locked {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw StateStoreError("SQLite prepare: \(lastError)")
            }
            defer { sqlite3_finalize(statement) }
            for (offset, argument) in arguments.enumerated() {
                bind(argument, at: Int32(offset + 1), in: statement)
            }
            var rows: [SQLRow] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw StateStoreError("SQLite step: \(lastError)") }
                rows.append(row(from: statement))
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func bind(_ value: SQLValue, at index: Int32, in statement: OpaquePointer) {
        switch value {
        case .integer(let number): sqlite3_bind_int64(statement, index, number)
        case .real(let number): sqlite3_bind_double(statement, index, number)
        case .text(let text): sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
        case .null: sqlite3_bind_null(statement, index)
        }
    }

    private func row(from statement: OpaquePointer) -> SQLRow {
        var columns: [String: SQLValue] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: columns[name] = .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT: columns[name] = .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                columns[name] = sqlite3_column_text(statement, index).map { .text(String(cString: $0)) } ?? .null
            default: columns[name] = .null
            }
        }
        return SQLRow(columns: columns)
    }
}
