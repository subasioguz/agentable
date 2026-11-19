import Foundation

/// What a stretch of SQL text is, for coloring it in an editor.
public enum SQLSpanKind: Sendable, Equatable {
    case keyword
    /// A name followed by `(`: `count`, `now`.
    case function
    case identifier
    case quoted
    case string
    case number
    case parameter
    case symbol
    case comment
}

/// A colored stretch of SQL. `range` counts UTF-8 bytes from the start of the text.
public struct SQLSpan: Sendable, Equatable {
    public let kind: SQLSpanKind
    public let range: Range<Int>
}

extension SQLAnalyzer {
    /// Spans for every token and comment, in order. Whitespace is left out.
    public static func spans(in sql: String, dialect: SQLDialect) -> [SQLSpan] {
        let tokens = SQLLexer.tokenize(sql, dialect: dialect)
        let bytes = Array(sql.utf8)
        var spans: [SQLSpan] = []
        var cursor = 0

        // The lexer skips comments with the whitespace; whatever else sits between tokens is one.
        func comments(upTo end: Int) {
            var start = cursor
            while start < end, isSpace(bytes[start]) { start += 1 }
            var last = end
            while last > start, isSpace(bytes[last - 1]) { last -= 1 }
            if start < last { spans.append(SQLSpan(kind: .comment, range: start..<last)) }
        }

        for (index, token) in tokens.enumerated() {
            comments(upTo: token.start)
            let kind: SQLSpanKind
            switch token.kind {
            case .word:
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                if next?.kind == .symbol && next?.text == "(" && !keywords.contains(token.upper) {
                    kind = .function
                } else {
                    kind = keywords.contains(token.upper) ? .keyword : .identifier
                }
            case .quoted: kind = .quoted
            case .string: kind = .string
            case .number: kind = .number
            case .parameter: kind = .parameter
            case .symbol, .semicolon: kind = .symbol
            }
            spans.append(SQLSpan(kind: kind, range: token.start..<token.end))
            cursor = token.end
        }
        comments(upTo: bytes.count)
        return spans
    }

    /// Where each top-level statement sits, in UTF-8 bytes, without its semicolon.
    public static func statementRanges(in sql: String, dialect: SQLDialect) -> [Range<Int>] {
        group(SQLLexer.tokenize(sql, dialect: dialect)).map { $0.first!.start..<$0.last!.end }
    }

    /// The statement the cursor is in or right after; between statements, the one before it.
    public static func statement(at offset: Int, in sql: String, dialect: SQLDialect) -> Range<Int>? {
        let ranges = statementRanges(in: sql, dialect: dialect)
        return ranges.last { $0.lowerBound <= offset } ?? ranges.first
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Words colored as keywords, and offered first when completing.
    public static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CAST", "CHECK",
        "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE", "CURRENT_TIMESTAMP", "DEFAULT",
        "DELETE", "DESC", "DISTINCT", "DO", "DROP", "ELSE", "END", "EXCEPT", "EXISTS", "EXPLAIN", "FALSE", "FILTER",
        "FIRST", "FOREIGN", "FROM", "FULL", "GRANT", "GROUP", "HAVING", "ILIKE", "IN", "INDEX", "INNER", "INSERT",
        "INTERSECT", "INTERVAL", "INTO", "IS", "JOIN", "KEY", "LAST", "LATERAL", "LEFT", "LIKE", "LIMIT", "NOT",
        "NOTHING", "NULL", "NULLS", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRAGMA", "PRIMARY",
        "RECURSIVE", "REFERENCES", "RETURNING", "REVOKE", "RIGHT", "ROLLBACK", "SELECT", "SET", "TABLE", "THEN", "TO",
        "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UPDATE", "USING", "VACUUM", "VALUES", "VIEW", "WHEN", "WHERE", "WINDOW",
        "WITH",
    ]
}
