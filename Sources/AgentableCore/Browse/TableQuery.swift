import Foundation

public struct SortKey: Sendable, Hashable, Codable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// One distinct value of a column and how many rows have it.
public struct ValueCount: Sendable, Hashable {
    public var value: CellValue
    public var count: Int
}

/// The SQL behind a table view: which table, filtered and sorted how. Paging always has a stable
/// order (the sort, then the primary key), so rows don't move between pages.
public struct TableQuery: Sendable, Hashable {
    public var table: TableRef
    public var dialect: SQLDialect
    public var filter: TableFilter
    public var sort: [SortKey]
    public var primaryKey: [String]
    /// Quick search: rows where any of `searchColumns` contains this text, on top of the filter.
    public var search: String?
    public var searchColumns: [String]

    public init(table: TableRef, dialect: SQLDialect, filter: TableFilter = TableFilter(), sort: [SortKey] = [], primaryKey: [String] = [], search: String? = nil, searchColumns: [String] = []) {
        self.table = table
        self.dialect = dialect
        self.filter = filter
        self.sort = sort
        self.primaryKey = primaryKey
        self.search = search
        self.searchColumns = searchColumns
    }

    /// The filter and the quick search, joined with AND; `nil` when neither applies.
    func conditions(_ builder: inout SQLBuilder, excluding: UUID? = nil) -> String? {
        var parts: [String] = []
        if let condition = filter.sql(&builder, excluding: excluding) { parts.append(condition) }
        if let search = search?.trimmingCharacters(in: .whitespaces), !search.isEmpty, !searchColumns.isEmpty {
            let like = dialect == .postgres ? "ILIKE" : "LIKE"
            let pattern = "%\(FilterCondition.escapeLike(search))%"
            let tests = searchColumns.map { column -> String in
                let asText = "CAST(\(SQLBuilder.quote(column)) AS \(dialect == .postgres ? "text" : "TEXT"))"
                return "\(asText) \(like) \(builder.value(.text(pattern))) ESCAPE '\\'"
            }
            parts.append("(" + tests.joined(separator: " OR ") + ")")
        }
        guard !parts.isEmpty else { return nil }
        return parts.count == 1 ? parts[0] : parts.map { $0.hasPrefix("(") ? $0 : "(\($0))" }.joined(separator: " AND ")
    }

    var orderBy: String? {
        var keys = sort.map { "\(SQLBuilder.quote($0.column)) \($0.ascending ? "ASC" : "DESC")" }
        let sorted = Set(sort.map(\.column))
        keys += primaryKey.filter { !sorted.contains($0) }.map { "\(SQLBuilder.quote($0)) ASC" }
        return keys.isEmpty ? nil : keys.joined(separator: ", ")
    }

    private func select(_ builder: inout SQLBuilder, limit: Int, offset: Int) -> String {
        var text = "SELECT * FROM \(table.sql)"
        if let condition = conditions(&builder) { text += " WHERE \(condition)" }
        if let orderBy { text += " ORDER BY \(orderBy)" }
        text += " LIMIT \(limit)"
        if offset > 0 { text += " OFFSET \(offset)" }
        return text
    }

    public func page(offset: Int, limit: Int) -> BoundSQL {
        var builder = SQLBuilder(dialect: dialect)
        let text = select(&builder, limit: limit, offset: offset)
        return builder.bound(text)
    }

    public func count() -> BoundSQL {
        var builder = SQLBuilder(dialect: dialect)
        var text = "SELECT count(*) FROM \(table.sql)"
        if let condition = conditions(&builder) { text += " WHERE \(condition)" }
        return builder.bound(text)
    }

    /// The most common values of `column` under the other conditions, for a value picker.
    public func valueCounts(column: String, excluding condition: UUID?, search: String?, limit: Int) -> BoundSQL {
        var builder = SQLBuilder(dialect: dialect)
        let c = SQLBuilder.quote(column)
        var clauses: [String] = []
        if let other = conditions(&builder, excluding: condition) { clauses.append(other) }
        if let search, !search.isEmpty {
            let like = dialect == .postgres ? "ILIKE" : "LIKE"
            let asText = "CAST(\(c) AS \(dialect == .postgres ? "text" : "TEXT"))"
            let pattern = builder.value(.text("%\(FilterCondition.escapeLike(search))%"))
            clauses.append("\(asText) \(like) \(pattern) ESCAPE '\\'")
        }
        var text = "SELECT \(c), count(*) AS n FROM \(table.sql)"
        if !clauses.isEmpty { text += " WHERE " + clauses.joined(separator: " AND ") }
        text += " GROUP BY \(c) ORDER BY n DESC, \(c) LIMIT \(limit)"
        return builder.bound(text)
    }

    /// The query as a person would read it, values written out.
    public func displaySQL(limit: Int = 500) -> String {
        var builder = SQLBuilder(dialect: dialect, inline: true)
        return select(&builder, limit: limit, offset: 0)
    }
}

/// Reads table pages, counts and value lists for the app, on the person's own read-only session.
public struct TableBrowser: Sendable {
    public let session: any DatabaseSession
    public let engine: DatabaseEngine
    public var timeout: Duration

    public init(session: any DatabaseSession, engine: DatabaseEngine, timeout: Duration = .seconds(30)) {
        self.session = session
        self.engine = engine
        self.timeout = timeout
    }

    public func page(_ query: TableQuery, offset: Int, limit: Int) async throws -> QueryResult {
        try await session.run(query.page(offset: offset, limit: limit), options: QueryOptions(readOnly: true, maxRows: limit, timeout: timeout))
    }

    public func count(_ query: TableQuery, timeout: Duration? = nil) async throws -> Int {
        let result = try await session.run(query.count(), options: QueryOptions(readOnly: true, maxRows: 1, timeout: timeout ?? self.timeout))
        return Self.int(result.rows.first?.first) ?? 0
    }

    public func valueCounts(_ query: TableQuery, column: String, excluding condition: UUID?, search: String? = nil, limit: Int = 50) async throws -> [ValueCount] {
        let sql = query.valueCounts(column: column, excluding: condition, search: search, limit: limit)
        let result = try await session.run(sql, options: QueryOptions(readOnly: true, maxRows: limit, timeout: timeout))
        return result.rows.map { ValueCount(value: $0[0], count: Self.int($0[1]) ?? 0) }
    }

    /// Rows per table: PostgreSQL's planner estimate (instant, approximate), SQLite's exact count.
    public func rowEstimates(_ tables: [TableSummary]) async throws -> [TableRef: Int] {
        var estimates: [TableRef: Int] = [:]
        switch engine {
        case .postgres:
            let result = try await session.run("""
                SELECT n.nspname::text, c.relname::text, c.reltuples::int8
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'p', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                """, options: QueryOptions(readOnly: true, maxRows: 100_000, timeout: .seconds(10)))
            for row in result.rows {
                guard case .text(let schema) = row[0], case .text(let name) = row[1], let count = Self.int(row[2]), count >= 0 else { continue }
                estimates[TableRef(schema: schema, name: name)] = count
            }
        case .sqlite:
            for table in tables where table.kind == .table {
                let ref = TableRef(table)
                let query = TableQuery(table: ref, dialect: .sqlite)
                if let count = try? await self.count(query, timeout: .seconds(2)) {
                    estimates[ref] = count
                }
            }
        }
        return estimates
    }

    static func int(_ value: CellValue?) -> Int? {
        switch value {
        case .integer(let number)?: Int(number)
        case .real(let number)?: Int(number)
        case .text(let text)?: Int(text)
        default: nil
        }
    }
}
