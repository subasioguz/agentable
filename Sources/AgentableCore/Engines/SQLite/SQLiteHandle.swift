import Foundation
import SQLite3

/// A sqlite3 connection. Not thread-safe: owners (actors) serialize access.
final class SQLiteHandle {
    let raw: OpaquePointer

    init(path: String, flags: Int32) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(rc)"
            sqlite3_close_v2(handle)
            throw DatabaseError.openFailed(message)
        }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 2_000)
        raw = handle
    }

    deinit {
        sqlite3_close_v2(raw)
    }

    var lastError: String { String(cString: sqlite3_errmsg(raw)) }
    var changes: Int { Int(sqlite3_changes(raw)) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(raw, sql, nil, nil, &error)
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw DatabaseError.statementFailed(message)
        }
    }

    /// Runs one parameterized statement and returns every row. For Agentable's own state and
    /// catalog queries, not for user SQL.
    @discardableResult
    func query(_ sql: String, _ bindings: [CellValue] = []) throws -> [[CellValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(raw, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.statementFailed(lastError)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try bind(value, at: Int32(offset + 1), in: statement)
        }
        let columnCount = sqlite3_column_count(statement)
        var rows: [[CellValue]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                rows.append((0..<columnCount).map { Self.value(statement, $0) })
            } else if rc == SQLITE_DONE {
                return rows
            } else {
                throw DatabaseError.statementFailed(lastError)
            }
        }
    }

    func bind(_ value: CellValue, at index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(statement, index)
        case .integer(let number):
            rc = sqlite3_bind_int64(statement, index, number)
        case .real(let number):
            rc = sqlite3_bind_double(statement, index, number)
        case .bool(let flag):
            rc = sqlite3_bind_int64(statement, index, flag ? 1 : 0)
        case .text(let text):
            rc = sqlite3_bind_text(statement, index, text, -1, transient)
        case .blob(let data):
            rc = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
            }
        }
        guard rc == SQLITE_OK else { throw DatabaseError.statementFailed(lastError) }
    }

    static func value(_ statement: OpaquePointer, _ index: Int32) -> CellValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .text("") }
            let count = Int(sqlite3_column_bytes(statement, index))
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default:
            return .null
        }
    }
}

/// Lets SQLite's progress handler stop a statement that runs past its deadline.
final class SQLiteDeadline: @unchecked Sendable {
    let deadline: ContinuousClock.Instant

    init(_ deadline: ContinuousClock.Instant) {
        self.deadline = deadline
    }

    var expired: Bool { ContinuousClock.now >= deadline }
}
