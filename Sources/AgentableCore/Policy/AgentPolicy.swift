import Foundation

/// What happens to an agent's SQL.
public enum PolicyDecision: Sendable, Equatable {
    /// Run it. `readOnly` sessions refuse writes at the engine level.
    case run(SQLStatement, readOnly: Bool)
    /// Store it in the review queue; a person decides.
    case propose(SQLStatement)
    /// Refuse, with a message written for the agent.
    case deny(String)
}

/// Routes agent SQL by the connection's access level. The engine's read-only mode and the database
/// role are the hard guarantees; this layer makes the common cases clear and fast.
public enum AgentPolicy {
    public static func evaluate(_ sql: String, on profile: ConnectionProfile) -> PolicyDecision {
        let access = profile.effectiveAgentAccess
        guard access != .off else {
            return .deny("Agents are off for \(profile.name).")
        }

        let statements = SQLAnalyzer.statements(in: sql, dialect: profile.engine.dialect)
        guard let statement = statements.first else {
            return .deny("The query is empty.")
        }
        guard statements.count == 1 else {
            return .deny("Send one statement per call. This query has \(statements.count).")
        }

        if let hidden = hiddenTable(in: statement, rules: profile.rules) {
            return .deny("\(hidden) is not available to agents on \(profile.name).")
        }

        switch statement.kind {
        case .read:
            return .run(statement, readOnly: true)
        case .write, .schema:
            switch access {
            case .off, .read:
                return .deny(
                    "\(profile.name) is read-only for agents. \(statement.verb) needs Propose access, which a person sets in Agentable."
                )
            case .propose:
                return .propose(statement)
            case .write:
                return .run(statement, readOnly: false)
            }
        case .transaction, .session, .other:
            return .deny(
                "\(statement.verb) statements are not available to agents. Agentable manages transactions and session settings."
            )
        }
    }

    /// Whether an agent may file a change for review on this connection.
    public static func evaluateProposal(_ sql: String, on profile: ConnectionProfile) -> PolicyDecision {
        guard profile.effectiveAgentAccess >= .propose else {
            return .deny("Agents can only read on \(profile.name), so changes cannot be proposed there.")
        }
        let statements = SQLAnalyzer.statements(in: sql, dialect: profile.engine.dialect)
        guard let statement = statements.first else { return .deny("The change is empty.") }
        guard statements.count == 1 else {
            return .deny("Propose one statement at a time. This has \(statements.count).")
        }
        if let hidden = hiddenTable(in: statement, rules: profile.rules) {
            return .deny("\(hidden) is not available to agents on \(profile.name).")
        }
        switch statement.kind {
        case .write, .schema:
            return .propose(statement)
        case .read:
            return .deny("This only reads data. Run it with `query` instead of proposing it.")
        case .transaction, .session, .other:
            return .deny("\(statement.verb) statements cannot be proposed. Agentable wraps changes in its own transaction.")
        }
    }

    static func hiddenTable(in statement: SQLStatement, rules: VisibilityRules) -> String? {
        rules.hiddenTables.first { rule in
            let table = rule.split(separator: ".").last.map { String($0).lowercased() } ?? rule.lowercased()
            return statement.identifiers.contains(table)
        }
    }

    public static func isHidden(table: String, rules: VisibilityRules) -> Bool {
        rules.hiddenTables.contains { rule in
            let hidden = rule.split(separator: ".").last.map(String.init) ?? rule
            return hidden.caseInsensitiveCompare(table) == .orderedSame
        }
    }
}
