import Foundation
import SQLite3

/// A session on a SQLite file.
///
/// Read-only sessions are guarded three ways: the file is opened read-only, `PRAGMA query_only`
/// is on, and every statement is checked with `sqlite3_stmt_readonly` before it runs.
public actor SQLiteSession: DatabaseSession {
    public enum Mode: Sendable {
        case readOnly
        case readWrite
        /// Read-write, creating the file if needed.
        case create
    }

    private let handle: SQLiteHandle
    private let mode: Mode

    public init(path: String, mode: Mode) throws {
        let flags: Int32
        switch mode {
        case .readOnly: flags = SQLITE_OPEN_READONLY
        case .readWrite: flags = SQLITE_OPEN_READWRITE
        case .create: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        let handle = try SQLiteHandle(path: path, flags: flags)
        if mode == .readOnly {
            try handle.exec("PRAGMA query_only = 1")
        }
        self.handle = handle
        self.mode = mode
    }

    public func run(_ query: BoundSQL, options: QueryOptions) throws -> QueryResult {
        let sql = query.text
        let pieces = SQLAnalyzer.statements(in: sql, dialect: .sqlite)
        guard !pieces.isEmpty else { throw DatabaseError.statementFailed("The query is empty.") }
        guard pieces.count == 1 else { throw DatabaseError.multipleStatements(pieces.count) }

        let started = ContinuousClock.now
        return try withDeadline(started.advanced(by: options.timeout), timeout: options.timeout) {
            let statement = try prepareSingle(sql)
            defer { sqlite3_finalize(statement) }
            try bind(query.binds, to: statement)

            let writes = sqlite3_stmt_readonly(statement) == 0
            if writes && (options.readOnly || mode == .readOnly) {
                throw DatabaseError.readOnlyViolation
            }

            let columnCount = sqlite3_column_count(statement)
            let columns = (0..<columnCount).map { column(statement, $0) }
            var rows: [[CellValue]] = []
            var truncated = false

            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_ROW {
                    if rows.count >= options.maxRows {
                        truncated = true
                        break
                    }
                    rows.append((0..<columnCount).map { SQLiteHandle.value(statement, $0) })
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw stepError(rc, timeout: options.timeout)
                }
            }

            return QueryResult(
                columns: columns,
                rows: rows,
                truncated: truncated,
                rowsAffected: writes ? handle.changes : nil,
                elapsed: ContinuousClock.now - started
            )
        }
    }

    public func trialRun(_ sql: String, timeout: Duration, maxRows: Int) throws -> TrialRun {
        guard mode != .readOnly else { throw DatabaseError.readOnlyViolation }
        let pieces = SQLAnalyzer.statements(in: sql, dialect: .sqlite)
        guard pieces.count == 1, let piece = pieces.first else { throw DatabaseError.multipleStatements(pieces.count) }
        try handle.exec("BEGIN")
        defer { try? handle.exec("ROLLBACK") }
        return try withDeadline(ContinuousClock.now.advanced(by: timeout), timeout: timeout) {
            if maxRows > 0, TrialRun.canReturnRows(piece), let statement = try? prepareSingle(piece.text + " RETURNING *") {
                defer { sqlite3_finalize(statement) }
                let columnCount = sqlite3_column_count(statement)
                let columns = (0..<columnCount).map { column(statement, $0) }
                var rows: [[CellValue]] = []
                var count = 0
                while true {
                    let rc = sqlite3_step(statement)
                    if rc == SQLITE_ROW {
                        count += 1
                        if rows.count < maxRows { rows.append((0..<columnCount).map { SQLiteHandle.value(statement, $0) }) }
                    } else if rc == SQLITE_DONE {
                        break
                    } else {
                        throw stepError(rc, timeout: timeout)
                    }
                }
                return TrialRun(rowsChanged: count, changed: QueryResult(columns: columns, rows: rows, truncated: count > rows.count))
            }
            return TrialRun(rowsChanged: try executeCountingChanges(sql, timeout: timeout))
        }
    }

    public func apply(_ statements: [BoundSQL], timeout: Duration) throws -> [Int] {
        guard mode != .readOnly else { throw DatabaseError.readOnlyViolation }
        try handle.exec("BEGIN IMMEDIATE")
        do {
            let counts = try withDeadline(ContinuousClock.now.advanced(by: timeout), timeout: timeout) {
                try statements.map { statement in
                    let count = try executeCountingChanges(statement.text, binds: statement.binds, timeout: timeout)
                    if let expected = statement.expectedRows, expected != count {
                        throw DatabaseError.unexpectedRowCount(expected: expected, actual: count)
                    }
                    return count
                }
            }
            try handle.exec("COMMIT")
            return counts
        } catch {
            try? handle.exec("ROLLBACK")
            throw error
        }
    }

    public func tables() throws -> [TableSummary] {
        try handle.query(
            "SELECT name, type FROM sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap { row in
            guard case .text(let name) = row[0], case .text(let type) = row[1] else { return nil }
            return TableSummary(name: name, kind: type == "view" ? .view : .table)
        }
    }

    public func describe(table name: String) throws -> TableDescription {
        guard let table = try tables().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw DatabaseError.tableNotFound(name)
        }
        let quoted = "\"\(table.name.replacingOccurrences(of: "\"", with: "\"\""))\""

        let columns = try handle.query("PRAGMA table_xinfo(\(quoted))").compactMap { row -> ColumnInfo? in
            guard let columnName = Self.text(row[1]) else { return nil }
            return ColumnInfo(
                name: columnName,
                type: Self.text(row[2]) ?? "",
                nullable: (Self.integer(row[3]) ?? 0) == 0 && (Self.integer(row[5]) ?? 0) == 0,
                defaultValue: row[4].isNull ? nil : row[4].displayText,
                primaryKey: (Self.integer(row[5]) ?? 0) > 0
            )
        }

        let foreignKeys = try handle.query("PRAGMA foreign_key_list(\(quoted))").compactMap { row -> ForeignKeyInfo? in
            guard let target = Self.text(row[2]), let from = Self.text(row[3]) else { return nil }
            return ForeignKeyInfo(column: from, referencedTable: target, referencedColumn: Self.text(row[4]))
        }

        let indexes = try handle.query("PRAGMA index_list(\(quoted))").compactMap { row -> IndexInfo? in
            guard let indexName = Self.text(row[1]) else { return nil }
            let quotedIndex = "\"\(indexName.replacingOccurrences(of: "\"", with: "\"\""))\""
            // index_xinfo: seqno, cid, name, desc, coll, key. Key columns only, with their order.
            let indexColumns = (try? handle.query("PRAGMA index_xinfo(\(quotedIndex))"))?.compactMap { row -> String? in
                guard Self.integer(row[5]) == 1, let name = Self.text(row[2]) else { return nil }
                return Self.integer(row[3]) == 1 ? name + " DESC" : name
            } ?? []
            // Origin "pk" and "u": made by PRIMARY KEY or UNIQUE in the table definition.
            let origin = Self.text(row[3]) ?? "c"
            return IndexInfo(name: indexName, columns: indexColumns, unique: (Self.integer(row[2]) ?? 0) != 0, constraint: origin != "c")
        }

        let createSQL = (try? handle.query("SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", [.text(table.name)]))?
            .first.flatMap { Self.text($0[0]) }
        let checks = createSQL.map { CheckInfo.parse(createTable: $0, columns: columns.map(\.name)) } ?? []

        return TableDescription(table: table, columns: columns, foreignKeys: foreignKeys, indexes: indexes, checks: checks)
    }

    public func references(to name: String) throws -> [IncomingReference] {
        let target = try describe(table: name)
        var found: [IncomingReference] = []
        for table in try tables() where table.kind == .table {
            let quoted = "\"\(table.name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let rows = try handle.query("PRAGMA foreign_key_list(\(quoted))")
            // Rows of one key share an id; keys over several columns are left out.
            let sizes = Dictionary(grouping: rows, by: { Self.integer($0[0]) ?? -1 }).mapValues(\.count)
            for row in rows {
                guard let id = Self.integer(row[0]), sizes[id] == 1,
                      let referenced = Self.text(row[2]), referenced.caseInsensitiveCompare(target.table.name) == .orderedSame,
                      let column = Self.text(row[3]) else { continue }
                found.append(IncomingReference(table: table.name, column: column, referencedColumn: Self.text(row[4])))
            }
        }
        return found
    }

    public func close() {}

    // MARK: - Helpers

    private static func text(_ value: CellValue) -> String? {
        if case .text(let text) = value { return text }
        return nil
    }

    private static func integer(_ value: CellValue) -> Int64? {
        if case .integer(let number) = value { return number }
        return nil
    }

    /// Prepares exactly one statement; anything after it (other than comments) is an error.
    private func prepareSingle(_ sql: String) throws -> OpaquePointer {
        let raw = handle.raw
        let (statement, rest): (OpaquePointer?, String) = try sql.withCString { text in
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(raw, text, -1, &statement, &tail) == SQLITE_OK else {
                throw DatabaseError.statementFailed(handle.lastError)
            }
            return (statement, tail.map { String(cString: $0) } ?? "")
        }
        guard let statement else { throw DatabaseError.statementFailed("The query is empty.") }
        let extra = SQLAnalyzer.statements(in: rest, dialect: .sqlite).count
        if extra > 0 {
            sqlite3_finalize(statement)
            throw DatabaseError.multipleStatements(extra + 1)
        }
        return statement
    }

    private func bind(_ values: [CellValue], to statement: OpaquePointer) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == values.count else {
            throw DatabaseError.statementFailed("The statement has \(expected) placeholders and \(values.count) values.")
        }
        for (offset, value) in values.enumerated() {
            try handle.bind(value, at: Int32(offset + 1), in: statement)
        }
    }

    private func executeCountingChanges(_ sql: String, binds: [CellValue] = [], timeout: Duration) throws -> Int {
        let statement = try prepareSingle(sql)
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw stepError(rc, timeout: timeout) }
        }
        return sqlite3_stmt_readonly(statement) == 0 ? handle.changes : 0
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> ResultColumn {
        ResultColumn(
            name: sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column\(index + 1)",
            typeName: sqlite3_column_decltype(statement, index).map { String(cString: $0) },
            sourceTable: sqlite3_column_table_name(statement, index).map { String(cString: $0) },
            sourceColumn: sqlite3_column_origin_name(statement, index).map { String(cString: $0) }
        )
    }

    private func stepError(_ rc: Int32, timeout: Duration) -> DatabaseError {
        if rc & 0xFF == SQLITE_INTERRUPT {
            return .timedOut(Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
        }
        if rc & 0xFF == SQLITE_READONLY {
            return .readOnlyViolation
        }
        return .statementFailed(handle.lastError)
    }

    /// Installs a progress handler that interrupts work past `deadline`, for the duration of `body`.
    private func withDeadline<T>(
        _ deadline: ContinuousClock.Instant,
        timeout: Duration,
        _ body: () throws -> T
    ) throws -> T {
        let raw = handle.raw
        let box = SQLiteDeadline(deadline)
        let context = Unmanaged.passRetained(box).toOpaque()
        sqlite3_progress_handler(raw, 1_000, { context in
            guard let context else { return 0 }
            return Unmanaged<SQLiteDeadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
        }, context)
        defer {
            sqlite3_progress_handler(raw, 0, nil, nil)
            Unmanaged<SQLiteDeadline>.fromOpaque(context).release()
        }
        return try body()
    }
}
