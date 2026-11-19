import Foundation
import AgentableCore

// Text for people about waiting changes, in the interface language. AgentableCore has English
// versions of these (`title`, `lockNote`, `summary`) for the CLI and agents; screens use these.

extension SchemaChange {
    /// "Add column gift_note", "Rename column note to gift_note".
    var localizedTitle: String {
        switch self {
        case .addColumn(let column):
            return String(localized: "Add column \(column.name)")
        case .alterColumn(let old, let new):
            let renameOnly = old.name != new.name && old.type == new.type && old.nullable == new.nullable && old.defaultValue == new.defaultValue
            return renameOnly
                ? String(localized: "Rename column \(old.name) to \(new.name)")
                : String(localized: "Change column \(old.name)")
        case .dropColumn(let column):
            return String(localized: "Drop column \(column.name)")
        case .addIndex(let index):
            return String(localized: "Add index \(index.name)")
        case .dropIndex(let index):
            return String(localized: "Drop index \(index.name)")
        }
    }

    /// What the change holds up while it runs, for PostgreSQL; `nil` for SQLite.
    func localizedLockNote(table: String, dialect: SQLDialect) -> String? {
        guard dialect == .postgres else { return nil }
        switch self {
        case .alterColumn(let old, let new) where old.type != new.type:
            return String(localized: "Rewrites \(table); reads and writes wait until it finishes.")
        case .alterColumn(let old, let new) where old.nullable && !new.nullable:
            return String(localized: "Scans \(table); reads and writes wait until it finishes.")
        case .addIndex:
            return String(localized: "Writes to \(table) wait while the index builds.")
        default:
            return String(localized: "Locks \(table) briefly.")
        }
    }
}

extension RowChange {
    /// "status shipped → delivered": column names and values stay as they are.
    var localizedSummary: String {
        switch kind {
        case .update, .sql:
            return summary
        case .delete:
            return String(localized: "delete row")
        case .insert(let values):
            if values.isEmpty { return String(localized: "insert a row of defaults") }
            let list = values.map { "\($0.column) \($0.value.displayText)" }.joined(separator: ", ")
            return String(localized: "insert \(list)")
        case .schema(let change):
            return change.localizedTitle
        }
    }
}
