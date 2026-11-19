import Foundation

public enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case openFailed(String)
    case statementFailed(String)
    case multipleStatements(Int)
    case readOnlyViolation
    case timedOut(Double)
    case tableNotFound(String)
    case unsupported(String)
    case missingDatabase
    case unexpectedRowCount(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .openFailed(let message): "Could not open the database: \(message)"
        case .statementFailed(let message): message
        case .multipleStatements(let count): "Send one statement per call. This query has \(count)."
        case .readOnlyViolation: "This statement writes, and the session is read-only."
        case .timedOut(let seconds): "The query ran longer than \(seconds.formatted()) s and was stopped."
        case .tableNotFound(let name): "No table or view named \(name)."
        case .unsupported(let message): message
        case .missingDatabase: "The connection has no database or file set."
        case .unexpectedRowCount(let expected, let actual):
            actual == 0
                ? "A row changed or disappeared since it was loaded, so nothing was applied. Reload and try again."
                : "A change would touch \(actual) rows instead of \(expected), so nothing was applied."
        }
    }
}

public struct TableSummary: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case table, view }
    public var schema: String?
    public var name: String
    public var kind: Kind

    public init(schema: String? = nil, name: String, kind: Kind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }
}

public struct ColumnInfo: Sendable, Hashable, Codable {
    public var name: String
    public var type: String
    public var nullable: Bool
    public var defaultValue: String?
    public var primaryKey: Bool
    /// PostgreSQL identity column: the database fills it.
    public var identity: Bool = false
}

public struct ForeignKeyInfo: Sendable, Hashable, Codable {
    public var column: String
    public var referencedTable: String
    public var referencedColumn: String?
    /// PostgreSQL only: the schema of the referenced table.
    public var referencedSchema: String? = nil
}

/// A foreign key in another table that points at this one: rows of `table` whose `column` holds a
/// value of this table's `referencedColumn`. Single-column keys only.
public struct IncomingReference: Sendable, Hashable, Codable {
    public var schema: String?
    public var table: String
    public var column: String
    /// `nil` when the key points at the primary key without naming it (SQLite).
    public var referencedColumn: String?

    public init(schema: String? = nil, table: String, column: String, referencedColumn: String?) {
        self.schema = schema
        self.table = table
        self.column = column
        self.referencedColumn = referencedColumn
    }
}

public struct IndexInfo: Sendable, Hashable, Codable {
    public var name: String
    public var columns: [String]
    public var unique: Bool
    /// Made by a primary key or unique constraint; dropped with the constraint, not on its own.
    public var constraint: Bool = false
    /// PostgreSQL: the access method (btree, gin, ...).
    public var method: String? = nil
    /// PostgreSQL: size on disk in bytes, and scans since statistics were last reset.
    public var size: Int64? = nil
    public var scans: Int64? = nil
}

/// A CHECK constraint and the columns it mentions.
public struct CheckInfo: Sendable, Hashable, Codable {
    public var name: String?
    /// The condition, without the CHECK keyword.
    public var definition: String
    public var columns: [String]

    public init(name: String?, definition: String, columns: [String]) {
        self.name = name
        self.definition = definition
        self.columns = columns
    }
}

public struct TableDescription: Sendable, Hashable, Codable {
    public var table: TableSummary
    public var columns: [ColumnInfo]
    public var foreignKeys: [ForeignKeyInfo]
    public var indexes: [IndexInfo]
    public var checks: [CheckInfo] = []
    /// PostgreSQL: table, indexes and TOAST on disk, in bytes.
    public var size: Int64? = nil
    /// PostgreSQL: views that read each column, by column name.
    public var views: [String: [String]] = [:]
}

/// One statement whose values travel separately from the SQL text, so they are never parsed as SQL.
/// Placeholders follow the engine: `$1, $2, …` for PostgreSQL, `?` for SQLite.
public struct BoundSQL: Sendable, Hashable {
    public var text: String
    public var binds: [CellValue]
    /// When set, `apply` rolls everything back unless the statement changes exactly this many rows.
    public var expectedRows: Int?

    public init(_ text: String, binds: [CellValue] = [], expectedRows: Int? = nil) {
        self.text = text
        self.binds = binds
        self.expectedRows = expectedRows
    }
}

/// An open connection to one database. Implementations are actors.
public protocol DatabaseSession: Sendable {
    /// Runs one statement within the options' limits.
    func run(_ query: BoundSQL, options: QueryOptions) async throws -> QueryResult
    /// Runs one statement inside a transaction that is always rolled back. Returns how many rows
    /// it changed and, for `UPDATE`, `DELETE` and `INSERT`, up to `maxRows` of those rows (as they
    /// would be after the change; for `DELETE`, as they were).
    func trialRun(_ sql: String, timeout: Duration, maxRows: Int) async throws -> TrialRun
    /// Runs statements in one transaction, all or nothing; returns rows changed by each.
    func apply(_ statements: [BoundSQL], timeout: Duration) async throws -> [Int]
    func tables() async throws -> [TableSummary]
    func describe(table: String) async throws -> TableDescription
    /// Single-column foreign keys in other tables (or this one) that point at `table`.
    func references(to table: String) async throws -> [IncomingReference]
    func close() async
}

/// What a statement did in a rolled-back trial run.
public struct TrialRun: Sendable {
    public var rowsChanged: Int
    /// The changed rows, when the statement could return them.
    public var changed: QueryResult?

    public init(rowsChanged: Int, changed: QueryResult? = nil) {
        self.rowsChanged = rowsChanged
        self.changed = changed
    }

    /// `RETURNING *` can be added to plain `UPDATE`, `DELETE` and `INSERT` statements.
    static func canReturnRows(_ statement: SQLStatement) -> Bool {
        ["UPDATE", "DELETE", "INSERT"].contains(statement.verb) && !statement.identifiers.contains("returning")
    }
}

extension DatabaseSession {
    /// Runs one statement inside a transaction that is always rolled back; returns rows changed.
    public func dryRun(_ sql: String, timeout: Duration) async throws -> Int {
        try await trialRun(sql, timeout: timeout, maxRows: 0).rowsChanged
    }

    public func run(_ sql: String, options: QueryOptions) async throws -> QueryResult {
        try await run(BoundSQL(sql), options: options)
    }

    public func apply(_ statements: [String], timeout: Duration) async throws -> [Int] {
        try await apply(statements.map { BoundSQL($0) }, timeout: timeout)
    }
}

/// Opens sessions for profiles. Swapped out in tests.
public protocol SessionFactory: Sendable {
    func open(_ profile: ConnectionProfile, password: String?, readOnly: Bool) async throws -> any DatabaseSession
}

public struct DefaultSessionFactory: SessionFactory {
    public init() {}

    public func open(_ profile: ConnectionProfile, password: String?, readOnly: Bool) async throws -> any DatabaseSession {
        switch profile.engine {
        case .sqlite:
            guard let path = profile.database, !path.isEmpty else { throw DatabaseError.missingDatabase }
            return try SQLiteSession(path: path, mode: readOnly ? .readOnly : .readWrite)
        case .postgres:
            return try await PostgresSession.connect(profile: profile, password: password, readOnly: readOnly)
        }
    }
}
