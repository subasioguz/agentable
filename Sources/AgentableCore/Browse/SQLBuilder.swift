import Foundation

/// A table, optionally in a schema, as the app addresses it.
public struct TableRef: Sendable, Hashable, Codable {
    public var schema: String?
    public var name: String

    public init(schema: String? = nil, name: String) {
        self.schema = schema
        self.name = name
    }

    public init(_ summary: TableSummary) {
        self.init(schema: summary.schema, name: summary.name)
    }

    /// `schema.table` when a schema is set, for lookups such as `describe(table:)`.
    public var path: String {
        schema.map { "\($0).\(name)" } ?? name
    }

    /// The quoted name for SQL.
    public var sql: String {
        if let schema { return "\(SQLBuilder.quote(schema)).\(SQLBuilder.quote(name))" }
        return SQLBuilder.quote(name)
    }
}

/// Builds SQL text with values kept apart as binds. With `inline` set, values are written as quoted
/// literals instead; that text is for showing people, never for running.
public struct SQLBuilder: Sendable {
    public let dialect: SQLDialect
    public let inline: Bool
    public private(set) var binds: [CellValue] = []

    public init(dialect: SQLDialect, inline: Bool = false) {
        self.dialect = dialect
        self.inline = inline
    }

    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func literal(_ value: CellValue) -> String {
        switch value {
        case .null: "NULL"
        case .integer(let number): String(number)
        case .real(let number): String(number)
        case .bool(let flag): flag ? "TRUE" : "FALSE"
        case .text(let text): "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        case .blob(let data): "x'" + data.map { String(format: "%02x", $0) }.joined() + "'"
        }
    }

    /// Adds a value and returns its placeholder (or literal, when inlining).
    public mutating func value(_ value: CellValue) -> String {
        if inline { return Self.literal(value) }
        binds.append(value)
        return dialect == .postgres ? "$\(binds.count)" : "?"
    }

    public func bound(_ text: String) -> BoundSQL {
        BoundSQL(text, binds: binds)
    }
}

extension DatabaseEngine {
    public var sqlDialect: SQLDialect { dialect }
}
