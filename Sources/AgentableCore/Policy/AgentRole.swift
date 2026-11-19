import Foundation

/// SQL that sets up a SELECT-only database role for agents: the layer that still holds if every
/// check inside Agentable were wrong.
public enum AgentRole {
    public static func setupSQL(role: String, database: String?, tables: [TableSummary], rules: VisibilityRules) -> String {
        let quotedRole = quote(role)
        var lines = [
            "-- Run as the database owner or a superuser. Choose a strong password.",
            "CREATE ROLE \(quotedRole) LOGIN PASSWORD 'change-me';",
            "ALTER ROLE \(quotedRole) SET default_transaction_read_only = on;",
        ]
        if let database, !database.isEmpty {
            lines.append("GRANT CONNECT ON DATABASE \(quote(database)) TO \(quotedRole);")
        }
        let visible = tables.filter { !AgentPolicy.isHidden(table: $0.name, rules: rules) }
        for schema in Set(visible.compactMap(\.schema)).sorted() {
            lines.append("GRANT USAGE ON SCHEMA \(quote(schema)) TO \(quotedRole);")
        }
        for table in visible {
            let name = (table.schema.map { quote($0) + "." } ?? "") + quote(table.name)
            lines.append("GRANT SELECT ON \(name) TO \(quotedRole);")
        }
        if !rules.hiddenTables.isEmpty {
            lines.append("-- No grant for hidden tables: \(rules.hiddenTables.joined(separator: ", "))")
        }
        lines.append("-- Tables created later need their own grant: run this command again after migrations.")
        return lines.joined(separator: "\n")
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
