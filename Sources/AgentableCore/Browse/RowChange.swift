import Foundation

/// A primary-key column and its value in the row being changed.
public struct KeyValue: Sendable, Hashable {
    public var column: String
    public var value: CellValue

    public init(column: String, value: CellValue) {
        self.column = column
        self.value = value
    }
}

/// A new value for one column, with the value it replaces.
public struct ColumnChange: Sendable, Hashable {
    public var column: String
    public var category: ColumnCategory
    public var old: CellValue
    public var new: CellValue

    public init(column: String, category: ColumnCategory, old: CellValue, new: CellValue) {
        self.column = column
        self.category = category
        self.old = old
        self.new = new
    }

    /// Whether the old value can be compared exactly, to catch rows changed since they were loaded.
    /// Floats and timestamps lose precision on the way to the grid, so they are not compared.
    var comparable: Bool {
        if case .real = old { return false }
        switch category {
        case .text, .integer, .boolean, .other: return true
        default: return false
        }
    }
}

/// A change the person staged in the grid. It waits with the agents' proposals and is applied in
/// the same transaction after review.
public struct RowChange: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case update([ColumnChange])
        case delete
        /// A new row with the values the person filled in. Columns left out get their defaults.
        case insert([KeyValue])
        /// A statement the person wrote in the SQL tab, run as written.
        case sql(String)
        /// A change to the table's columns or indexes, from the Structure tab.
        case schema(SchemaChange)
    }

    public var id: UUID
    public var table: TableRef
    public var key: [KeyValue]
    public var kind: Kind
    public var createdAt: Date

    public init(id: UUID = UUID(), table: TableRef, key: [KeyValue], kind: Kind, createdAt: Date = .now) {
        self.id = id
        self.table = table
        self.key = key
        self.kind = kind
        self.createdAt = createdAt
    }

    public var keyLabel: String {
        switch kind {
        case .insert: return "new row"
        case .sql: return "SQL"
        case .schema: return "structure"
        default: return key.map { $0.value.displayText }.joined(separator: " · ")
        }
    }

    public var isInsert: Bool {
        if case .insert = kind { return true }
        return false
    }

    public var schemaChange: SchemaChange? {
        if case .schema(let change) = kind { return change }
        return nil
    }

    /// Edits and deletes of the same row combine into one change; new rows and SQL never do.
    public var mergesByRow: Bool {
        switch kind {
        case .update, .delete: true
        case .insert, .sql, .schema: false
        }
    }

    /// "status shipped → delivered"
    public var summary: String {
        switch kind {
        case .update(let changes):
            changes.map { "\($0.column) \($0.old.displayText) → \($0.new.displayText)" }.joined(separator: ", ")
        case .delete:
            "delete row"
        case .insert(let values):
            values.isEmpty ? "insert a row of defaults" : "insert " + values.map { "\($0.column) \($0.value.displayText)" }.joined(separator: ", ")
        case .sql(let text):
            String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(160))
        case .schema(let change):
            change.title
        }
    }

    /// The statement, which must change exactly one row. Updated columns that can be compared
    /// exactly must still hold their old value, so a row someone else changed meanwhile is not
    /// overwritten.
    public func statement(dialect: SQLDialect) -> BoundSQL {
        var builder = SQLBuilder(dialect: dialect)
        let same = dialect == .postgres ? "IS NOT DISTINCT FROM" : "IS"
        // Placeholders are added in text order: SQLite binds `?` by position.
        var text: String
        var changes: [ColumnChange] = []
        switch kind {
        case .update(let updated):
            changes = updated
            let sets = updated.map { "\(SQLBuilder.quote($0.column)) = \(builder.value($0.new))" }
            text = "UPDATE \(table.sql) SET \(sets.joined(separator: ", "))"
        case .delete:
            text = "DELETE FROM \(table.sql)"
        case .insert(let values):
            let insert = Self.insertText(table: table, values: values, builder: &builder)
            var bound = builder.bound(insert)
            bound.expectedRows = 1
            return bound
        case .sql(let text):
            return BoundSQL(text)
        case .schema(let change):
            // Can be two statements; `statements(dialect:)` keeps them apart.
            return BoundSQL(change.text(table: table, dialect: dialect).joined(separator: ";\n"))
        }
        var conditions = key.map { "\(SQLBuilder.quote($0.column)) = \(builder.value($0.value))" }
        for change in changes where change.comparable {
            conditions.append("\(SQLBuilder.quote(change.column)) \(same) \(builder.value(change.old))")
        }
        text += " WHERE " + conditions.joined(separator: " AND ")
        var bound = builder.bound(text)
        bound.expectedRows = 1
        return bound
    }

    /// The statement with values written out, for the review screen.
    public func displaySQL(dialect: SQLDialect) -> String {
        var builder = SQLBuilder(dialect: dialect, inline: true)
        switch kind {
        case .update(let changes):
            let sets = changes.map { "\(SQLBuilder.quote($0.column)) = \(builder.value($0.new))" }
            let where_ = key.map { "\(SQLBuilder.quote($0.column)) = \(builder.value($0.value))" }
            return "UPDATE \(table.sql) SET \(sets.joined(separator: ", ")) WHERE \(where_.joined(separator: " AND "))"
        case .delete:
            let where_ = key.map { "\(SQLBuilder.quote($0.column)) = \(builder.value($0.value))" }
            return "DELETE FROM \(table.sql) WHERE \(where_.joined(separator: " AND "))"
        case .insert(let values):
            return Self.insertText(table: table, values: values, builder: &builder)
        case .sql(let text):
            return text
        case .schema(let change):
            return change.text(table: table, dialect: dialect).joined(separator: ";\n")
        }
    }

    /// Every statement the change runs, in order. Structure changes are checked first and can be
    /// two statements; everything else is one.
    public func statements(dialect: SQLDialect) throws -> [BoundSQL] {
        guard case .schema(let change) = kind else { return [statement(dialect: dialect)] }
        return try change.statements(table: table, dialect: dialect).map { BoundSQL($0) }
    }

    private static func insertText(table: TableRef, values: [KeyValue], builder: inout SQLBuilder) -> String {
        guard !values.isEmpty else { return "INSERT INTO \(table.sql) DEFAULT VALUES" }
        let names = values.map { SQLBuilder.quote($0.column) }.joined(separator: ", ")
        let placeholders = values.map { builder.value($0.value) }.joined(separator: ", ")
        return "INSERT INTO \(table.sql) (\(names)) VALUES (\(placeholders))"
    }
}
