import Foundation

/// What a statement does, as far as Agentable can tell from the text.
///
/// This drives messages and routing (run, propose, refuse). It is not the security boundary: a
/// function call inside a `SELECT` can still have side effects. Read-only sessions and the
/// database role are what actually stop writes.
public enum StatementKind: String, Sendable, Codable {
    /// Returns data and changes nothing.
    case read
    /// Changes or locks rows.
    case write
    /// Changes structure, permissions or runs maintenance.
    case schema
    /// BEGIN, COMMIT, ROLLBACK, SAVEPOINT and friends.
    case transaction
    /// SET, RESET and other session settings.
    case session
    case other
}

public struct SQLStatement: Sendable, Equatable {
    /// The statement without its trailing semicolon.
    public let text: String
    public let kind: StatementKind
    /// The first keyword, upper-cased (`SELECT`, `WITH`, `UPDATE`, ...).
    public let verb: String
    /// Lower-cased bare and quoted names the statement mentions.
    public let identifiers: Set<String>
}

public enum SQLAnalyzer {
    /// Top-level statements in `sql`. Comment-only pieces are dropped.
    public static func statements(in sql: String, dialect: SQLDialect) -> [SQLStatement] {
        let tokens = SQLLexer.tokenize(sql, dialect: dialect)
        let bytes = Array(sql.utf8)
        return group(tokens).map { tokens in
            let text = String(decoding: bytes[tokens.first!.start..<tokens.last!.end], as: UTF8.self)
            let identifiers = Set(
                tokens.filter { $0.kind == .word || $0.kind == .quoted }.map { $0.text.lowercased() }
            )
            return SQLStatement(
                text: text,
                kind: classify(tokens[...]),
                verb: tokens.first { $0.kind == .word }?.upper ?? "",
                identifiers: identifiers
            )
        }
    }

    /// The table an `UPDATE`, `DELETE` or `INSERT` changes, as `(schema, name)`; `nil` for other
    /// statements or when the target is not a plain name.
    public static func writeTarget(of sql: String, dialect: SQLDialect) -> (schema: String?, name: String)? {
        let tokens = SQLLexer.tokenize(sql, dialect: dialect)
        guard let verb = tokens.first(where: { $0.kind == .word })?.upper,
              let start = tokens.firstIndex(where: { $0.kind == .word }) else { return nil }
        var index = start + 1
        func skip(_ words: Set<String>) {
            if index < tokens.count, tokens[index].kind == .word, words.contains(tokens[index].upper) { index += 1 }
        }
        let conflictClauses: Set<String> = ["ROLLBACK", "ABORT", "REPLACE", "FAIL", "IGNORE"]
        switch verb {
        case "UPDATE":
            skip(["OR"])
            skip(conflictClauses)
        case "DELETE":
            skip(["FROM"])
        case "INSERT", "REPLACE":
            skip(["OR"])
            skip(conflictClauses)
            skip(["INTO"])
        default:
            return nil
        }
        skip(["ONLY"])
        func name(at position: Int) -> String? {
            guard position < tokens.count else { return nil }
            let token = tokens[position]
            return token.kind == .word || token.kind == .quoted ? token.text : nil
        }
        guard let first = name(at: index) else { return nil }
        if index + 2 < tokens.count, tokens[index + 1].kind == .symbol, tokens[index + 1].text == ".", let second = name(at: index + 2) {
            return (first, second)
        }
        return (nil, first)
    }

    /// Splits on top-level semicolons. Semicolons inside `BEGIN … END` bodies of `CREATE`
    /// statements (SQLite triggers, Postgres `BEGIN ATOMIC`) do not split.
    static func group(_ tokens: [SQLToken]) -> [[SQLToken]] {
        var groups: [[SQLToken]] = []
        var current: [SQLToken] = []
        var blockDepth = 0
        var caseDepth = 0

        for token in tokens {
            if token.kind == .semicolon {
                if blockDepth > 0 {
                    current.append(token)
                    continue
                }
                if !current.isEmpty { groups.append(current) }
                current = []
                caseDepth = 0
                continue
            }
            if token.kind == .word, current.first?.upper == "CREATE" {
                switch token.upper {
                case "BEGIN":
                    blockDepth += 1
                case "CASE" where blockDepth > 0:
                    caseDepth += 1
                case "END":
                    if caseDepth > 0 {
                        caseDepth -= 1
                    } else if blockDepth > 0 {
                        blockDepth -= 1
                    }
                default:
                    break
                }
            }
            current.append(token)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    static func classify(_ tokens: ArraySlice<SQLToken>) -> StatementKind {
        var rest = tokens
        while let first = rest.first, first.kind == .symbol, first.text == "(" {
            rest = rest.dropFirst()
        }
        guard let first = rest.first, first.kind == .word else { return .other }

        switch first.upper {
        case "SELECT":
            return selectKind(rest)
        case "WITH":
            let modifies = rest.contains {
                $0.kind == .word && ["INSERT", "UPDATE", "DELETE", "MERGE"].contains($0.upper)
            }
            return modifies ? .write : selectKind(rest)
        case "VALUES", "TABLE", "SHOW", "DESCRIBE", "DESC":
            return .read
        case "EXPLAIN":
            return explainKind(rest)
        case "PRAGMA":
            return pragmaKind(rest)
        case "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "UPSERT", "COPY", "LOCK", "NOTIFY", "CALL", "DO":
            return .write
        case "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "COMMENT", "GRANT", "REVOKE", "REINDEX",
             "VACUUM", "ANALYZE", "ANALYSE", "CLUSTER", "REFRESH", "ATTACH", "DETACH", "SECURITY",
             "IMPORT", "REASSIGN", "CHECKPOINT":
            return .schema
        case "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE", "PREPARE":
            return .transaction
        case "SET", "RESET", "DISCARD", "LISTEN", "UNLISTEN", "LOAD":
            return .session
        default:
            return .other
        }
    }

    /// `SELECT … INTO new_table` creates a table; `FOR UPDATE/SHARE` takes row locks.
    private static func selectKind(_ tokens: ArraySlice<SQLToken>) -> StatementKind {
        var depth = 0
        var sawFrom = false
        let list = Array(tokens)
        for (index, token) in list.enumerated() {
            if token.kind == .symbol {
                if token.text == "(" { depth += 1 } else if token.text == ")" { depth -= 1 }
                continue
            }
            guard token.kind == .word, depth == 0 else { continue }
            switch token.upper {
            case "FROM":
                sawFrom = true
            case "INTO" where !sawFrom:
                return .schema
            case "FOR":
                if index + 1 < list.count, list[index + 1].kind == .word,
                   ["UPDATE", "SHARE", "NO", "KEY"].contains(list[index + 1].upper) {
                    return .write
                }
            default:
                break
            }
        }
        return .read
    }

    /// Plain `EXPLAIN` only plans. `EXPLAIN ANALYZE` runs the statement, so it is as risky as it is.
    private static func explainKind(_ tokens: ArraySlice<SQLToken>) -> StatementKind {
        let list = Array(tokens)
        var index = 1
        var analyze = false
        let optionWords: Set<String> = [
            "VERBOSE", "QUERY", "PLAN", "COSTS", "BUFFERS", "FORMAT", "TEXT", "JSON", "YAML", "XML",
            "SETTINGS", "WAL", "TIMING", "SUMMARY", "MEMORY", "SERIALIZE", "GENERIC_PLAN",
        ]
        while index < list.count {
            let token = list[index]
            if token.kind == .symbol, token.text == "(" {
                var depth = 1
                var options: [String] = []
                index += 1
                while index < list.count, depth > 0 {
                    let option = list[index]
                    if option.kind == .symbol, option.text == "(" { depth += 1 }
                    if option.kind == .symbol, option.text == ")" { depth -= 1 }
                    if option.kind == .word { options.append(option.upper) }
                    index += 1
                }
                if let at = options.firstIndex(where: { $0 == "ANALYZE" || $0 == "ANALYSE" }) {
                    let value = at + 1 < options.count ? options[at + 1] : "TRUE"
                    analyze = !["FALSE", "OFF"].contains(value)
                }
                continue
            }
            if token.kind == .word {
                if token.upper == "ANALYZE" || token.upper == "ANALYSE" {
                    analyze = true
                    index += 1
                    continue
                }
                if optionWords.contains(token.upper) {
                    index += 1
                    continue
                }
                break
            }
            index += 1
        }
        guard analyze, index < list.count else { return .read }
        return classify(list[index...])
    }

    private static let readOnlyPragmas: Set<String> = [
        "table_info", "table_xinfo", "table_list", "index_list", "index_info", "index_xinfo",
        "foreign_key_list", "database_list", "collation_list", "function_list", "compile_options",
    ]

    private static func pragmaKind(_ tokens: ArraySlice<SQLToken>) -> StatementKind {
        let list = Array(tokens)
        if list.contains(where: { $0.kind == .symbol && $0.text == "=" }) { return .session }
        guard list.count > 1 else { return .session }
        var name = list[1].text
        if list.count > 3, list[2].text == "." { name = list[3].text }
        return readOnlyPragmas.contains(name.lowercased()) ? .read : .session
    }
}
