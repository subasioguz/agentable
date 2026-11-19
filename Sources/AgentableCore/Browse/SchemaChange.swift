import Foundation

/// A column as the structure editor shows and changes it.
public struct ColumnShape: Sendable, Hashable {
    public var name: String
    public var type: String
    public var nullable: Bool
    /// An SQL expression: as the database reports it, or as the person typed it.
    public var defaultValue: String?

    public init(name: String, type: String, nullable: Bool = true, defaultValue: String? = nil) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
    }

    public init(_ info: ColumnInfo) {
        self.init(name: info.name, type: info.type, nullable: info.nullable, defaultValue: info.defaultValue)
    }
}

/// An index as the structure editor creates or drops it.
public struct IndexShape: Sendable, Hashable {
    public var name: String
    public var columns: [String]
    public var unique: Bool

    public init(name: String, columns: [String], unique: Bool = false) {
        self.name = name
        self.columns = columns
        self.unique = unique
    }

    public init(_ info: IndexInfo) {
        self.init(name: info.name, columns: info.columns, unique: info.unique)
    }

    /// "orders_status_created_at_idx"
    public static func suggestedName(table: String, columns: [String], unique: Bool) -> String {
        let parts = [table] + columns.map { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? $0 }
        return String((parts.joined(separator: "_") + (unique ? "_key" : "_idx")).prefix(63))
    }
}

/// A change to a table's structure. It waits with row edits and runs in the same transaction:
/// PostgreSQL and SQLite both roll DDL back, so a batch that fails changes nothing.
///
/// Names are always quoted. Types and defaults are SQL the person typed; they are checked to be a
/// plain type name and a single expression before any statement is built.
public enum SchemaChange: Sendable, Hashable {
    case addColumn(ColumnShape)
    /// Rename, type, default and empty values of an existing column; `old` is as it was loaded.
    case alterColumn(old: ColumnShape, new: ColumnShape)
    case dropColumn(ColumnShape)
    case addIndex(IndexShape)
    case dropIndex(IndexShape)

    /// "Add column gift_note", "Rename column note to gift_note".
    public var title: String {
        switch self {
        case .addColumn(let column): "Add column \(column.name)"
        case .alterColumn(let old, let new):
            old.name != new.name && old.type == new.type && old.nullable == new.nullable && old.defaultValue == new.defaultValue
                ? "Rename column \(old.name) to \(new.name)"
                : "Change column \(old.name)"
        case .dropColumn(let column): "Drop column \(column.name)"
        case .addIndex(let index): "Add index \(index.name)"
        case .dropIndex(let index): "Drop index \(index.name)"
        }
    }

    /// The column this change is about, by the name it had when loaded (new columns by their name).
    public var columnName: String? {
        switch self {
        case .addColumn(let column), .dropColumn(let column): column.name
        case .alterColumn(let old, _): old.name
        case .addIndex, .dropIndex: nil
        }
    }

    public var indexName: String? {
        switch self {
        case .addIndex(let index), .dropIndex(let index): index.name
        default: nil
        }
    }

    // MARK: Checks

    /// Why this change can't run on `dialect`, or `nil` when it can.
    public func problem(dialect: SQLDialect) -> String? {
        switch self {
        case .addColumn(let column):
            if let problem = Self.nameProblem(column.name, dialect: dialect) ?? Self.typeProblem(column.type) ?? Self.defaultProblem(column.defaultValue, dialect: dialect) {
                return problem
            }
            if dialect == .sqlite && !column.nullable && column.defaultValue == nil {
                return "SQLite needs a default for a new column that doesn't allow empty values."
            }
            return nil
        case .alterColumn(let old, let new):
            if dialect == .sqlite && (old.type != new.type || old.nullable != new.nullable || old.defaultValue != new.defaultValue) {
                return "SQLite can only rename a column. Changing its type, default or empty values means rebuilding the table."
            }
            if old.name != new.name, let problem = Self.nameProblem(new.name, dialect: dialect) { return problem }
            if old.type != new.type, let problem = Self.typeProblem(new.type) { return problem }
            if old.defaultValue != new.defaultValue, let problem = Self.defaultProblem(new.defaultValue, dialect: dialect) { return problem }
            return nil
        case .dropColumn:
            return nil
        case .addIndex(let index):
            if let problem = Self.nameProblem(index.name, dialect: dialect) { return problem }
            return index.columns.isEmpty ? "Choose at least one column for the index." : nil
        case .dropIndex:
            return nil
        }
    }

    static func nameProblem(_ name: String, dialect: SQLDialect) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 }) { return "Names can't contain control characters." }
        if dialect == .postgres && name.utf8.count > 63 { return "PostgreSQL names are at most 63 bytes." }
        return nil
    }

    /// A type is a plain name with optional sizes and array brackets: `text`, `numeric(10,2)`,
    /// `timestamp(3) with time zone`, `varchar(80)[]`, `public.order_status`, `"Mood"`.
    static func typeProblem(_ type: String) -> String? {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" || first == "\"" else {
            return "Type a type name, like text or numeric(10,2)."
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_ ,.()[]\""))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            return "“\(trimmed)” isn't a type name."
        }
        var depth = 0
        var quoted = false
        for character in trimmed {
            switch character {
            case "\"": quoted.toggle()
            case "(" where !quoted:
                depth += 1
                if depth > 1 { return "“\(trimmed)” isn't a type name." }
            case ")" where !quoted:
                depth -= 1
                if depth < 0 { return "“\(trimmed)” isn't a type name." }
            default:
                // Inside parentheses only sizes: digits, commas and spaces.
                if depth == 1 && !quoted && !(character.isNumber || character == "," || character == " ") {
                    return "“\(trimmed)” isn't a type name."
                }
            }
        }
        return depth == 0 && !quoted ? nil : "“\(trimmed)” isn't a type name."
    }

    /// A default is one expression: no statement separators, no comments, balanced parentheses.
    static func defaultProblem(_ expression: String?, dialect: SQLDialect) -> String? {
        guard let expression else { return nil }
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Leave the default empty to remove it." }
        let problem = "A default is one expression, like 'pending', 0 or now()."
        let tokens = SQLLexer.tokenize(trimmed, dialect: dialect)
        if tokens.contains(where: { $0.kind == .semicolon }) { return problem }
        // The lexer skips comments: anything it left out that isn't whitespace was one.
        let bytes = Array(trimmed.utf8)
        var covered = [Bool](repeating: false, count: bytes.count)
        for token in tokens {
            for offset in token.start..<min(token.end, bytes.count) { covered[offset] = true }
        }
        for (offset, byte) in bytes.enumerated() where !covered[offset] && ![0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            return problem
        }
        var depth = 0
        for token in tokens where token.kind == .symbol {
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
            if depth < 0 { return problem }
        }
        return depth == 0 ? nil : problem
    }

    // MARK: Statements

    /// The statements, in order. Most changes are one statement; renaming a column and changing
    /// it in the same step takes two on PostgreSQL.
    public func statements(table: TableRef, dialect: SQLDialect) throws -> [String] {
        if let problem = problem(dialect: dialect) { throw DatabaseError.unsupported(problem) }
        return text(table: table, dialect: dialect)
    }

    /// The statements, without checks, for showing.
    public func text(table: TableRef, dialect: SQLDialect) -> [String] {
        let target = table.sql
        let quote = SQLBuilder.quote
        switch self {
        case .addColumn(let column):
            var definition = "\(quote(column.name)) \(column.type.trimmingCharacters(in: .whitespaces))"
            if let value = column.defaultValue { definition += " DEFAULT \(value.trimmingCharacters(in: .whitespacesAndNewlines))" }
            if !column.nullable { definition += " NOT NULL" }
            return ["ALTER TABLE \(target) ADD COLUMN \(definition)"]
        case .alterColumn(let old, let new):
            var statements: [String] = []
            if old.name != new.name {
                statements.append("ALTER TABLE \(target) RENAME COLUMN \(quote(old.name)) TO \(quote(new.name))")
            }
            let name = quote(new.name)
            let type = new.type.trimmingCharacters(in: .whitespaces)
            var actions: [String] = []
            let typeChanged = old.type != new.type
            let defaultChanged = old.defaultValue != new.defaultValue
            // An old default that can't be cast would stop the type change, so a replaced default
            // is dropped first (PostgreSQL runs drops before type changes, and sets after them).
            let dropFirst = typeChanged && defaultChanged && old.defaultValue != nil
            if dropFirst { actions.append("ALTER COLUMN \(name) DROP DEFAULT") }
            if typeChanged { actions.append("ALTER COLUMN \(name) TYPE \(type) USING \(name)::\(type)") }
            if defaultChanged {
                if let value = new.defaultValue {
                    actions.append("ALTER COLUMN \(name) SET DEFAULT \(value.trimmingCharacters(in: .whitespacesAndNewlines))")
                } else if !dropFirst {
                    actions.append("ALTER COLUMN \(name) DROP DEFAULT")
                }
            }
            if old.nullable != new.nullable {
                actions.append("ALTER COLUMN \(name) \(new.nullable ? "DROP" : "SET") NOT NULL")
            }
            if !actions.isEmpty {
                statements.append("ALTER TABLE \(target) " + actions.joined(separator: ", "))
            }
            return statements
        case .dropColumn(let column):
            return ["ALTER TABLE \(target) DROP COLUMN \(quote(column.name))"]
        case .addIndex(let index):
            let columns = index.columns.map(quote).joined(separator: ", ")
            return ["CREATE \(index.unique ? "UNIQUE " : "")INDEX \(quote(index.name)) ON \(target) (\(columns))"]
        case .dropIndex(let index):
            let name = table.schema.map { "\(quote($0)).\(quote(index.name))" } ?? quote(index.name)
            return ["DROP INDEX \(name)"]
        }
    }

    /// What the change holds up while it runs, for PostgreSQL; `nil` for SQLite, which locks the
    /// whole file for every write anyway.
    public func lockNote(table: String, dialect: SQLDialect) -> String? {
        guard dialect == .postgres else { return nil }
        switch self {
        case .alterColumn(let old, let new) where old.type != new.type:
            return "Rewrites \(table); reads and writes wait until it finishes."
        case .alterColumn(let old, let new) where old.nullable && !new.nullable:
            return "Scans \(table); reads and writes wait until it finishes."
        case .addIndex:
            return "Writes to \(table) wait while the index builds."
        default:
            return "Locks \(table) briefly."
        }
    }
}

extension CheckInfo {
    /// "CHECK ((total >= 0))" → "total >= 0".
    public static func condition(_ definition: String) -> String {
        var text = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("CHECK") { text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        if text.uppercased().hasSuffix(" NOT VALID") { text = String(text.dropLast(10)) }
        while text.hasPrefix("("), text.hasSuffix(")"), Self.wrapped(text) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Whether the first parenthesis closes at the very end.
    private static func wrapped(_ text: String) -> Bool {
        var depth = 0
        for (offset, character) in text.enumerated() {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth == 0 { return offset == text.count - 1 }
        }
        return false
    }

    /// The values a column may hold, when the check lists them:
    /// `status IN ('a', 'b')`, or PostgreSQL's `status = ANY (ARRAY['a'::text, 'b'::text])`.
    public var allowedValues: [String]? {
        let upper = definition.uppercased().replacingOccurrences(of: " ", with: "")
        guard columns.count == 1, upper.contains("IN(") || upper.contains("ANY(ARRAY[") else { return nil }
        let values = SQLLexer.tokenize(definition, dialect: .postgres).filter { $0.kind == .string }.compactMap { token -> String? in
            guard token.text.hasPrefix("'"), token.text.hasSuffix("'"), token.text.count >= 2 else { return nil }
            return String(token.text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return values.isEmpty ? nil : values
    }

    /// "6 values", "≥ 0", or `nil` for anything else.
    public var shortLabel: String? {
        if let values = allowedValues { return "\(values.count) value\(values.count == 1 ? "" : "s")" }
        guard columns.count == 1,
              let match = definition.firstMatch(of: #/^\(?"?[\w ]+"?\)?\s*(>=|<=|<>|!=|>|<)\s*\(?'?(-?[0-9][0-9.]*)'?\)?(::[a-z ]+)?$/#) else { return nil }
        let symbol = ["<=": "≤", ">=": "≥", "<>": "≠", "!=": "≠"][String(match.1)] ?? String(match.1)
        return "\(symbol) \(match.2)"
    }

    /// CHECK constraints in a `CREATE TABLE` statement, as SQLite keeps it in `sqlite_schema`.
    public static func parse(createTable sql: String, columns: [String]) -> [CheckInfo] {
        let tokens = SQLLexer.tokenize(sql, dialect: .sqlite)
        let bytes = Array(sql.utf8)
        var found: [CheckInfo] = []
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            guard tokens[index].kind == .word, tokens[index].upper == "CHECK",
                  index + 1 < tokens.count, tokens[index + 1].text == "(" else { continue }
            var depth = 0
            var end = index + 1
            while end < tokens.count {
                if tokens[end].text == "(" && tokens[end].kind == .symbol { depth += 1 }
                if tokens[end].text == ")" && tokens[end].kind == .symbol {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }
            guard end < tokens.count else { break }
            let inner = String(decoding: bytes[tokens[index + 1].end..<tokens[end].start], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mentioned = Set(tokens[(index + 1)...end].filter { $0.kind == .word || $0.kind == .quoted }.map { $0.text.lowercased() })
            var name: String?
            if index >= 2, tokens[index - 2].kind == .word, tokens[index - 2].upper == "CONSTRAINT" { name = tokens[index - 1].text }
            // A check inside a column definition belongs to that column even if it names others.
            found.append(CheckInfo(name: name, definition: inner, columns: columns.filter { mentioned.contains($0.lowercased()) }))
            index = end
        }
        return found
    }
}

/// A `CREATE INDEX` statement, read back: the structure tab shows an agent's proposed index in
/// the table's index list.
public struct ProposedIndex: Sendable, Hashable {
    public var table: TableRef
    public var index: IndexShape
    public var method: String?
    public var concurrently: Bool

    /// `CREATE [UNIQUE] INDEX [CONCURRENTLY] [IF NOT EXISTS] name ON [ONLY] table [USING method] (columns)`.
    public static func parse(_ sql: String, dialect: SQLDialect) -> ProposedIndex? {
        let tokens = SQLLexer.tokenize(sql, dialect: dialect)
        var position = 0
        func word(_ expected: String) -> Bool {
            guard position < tokens.count, tokens[position].kind == .word, tokens[position].upper == expected else { return false }
            position += 1
            return true
        }
        func name() -> String? {
            guard position < tokens.count, tokens[position].kind == .word || tokens[position].kind == .quoted else { return nil }
            defer { position += 1 }
            return tokens[position].text
        }
        func symbol(_ text: String) -> Bool {
            guard position < tokens.count, tokens[position].kind == .symbol, tokens[position].text == text else { return false }
            position += 1
            return true
        }
        guard word("CREATE") else { return nil }
        let unique = word("UNIQUE")
        guard word("INDEX") else { return nil }
        let concurrently = word("CONCURRENTLY")
        if word("IF") { guard word("NOT"), word("EXISTS") else { return nil } }
        guard let indexName = name(), word("ON") else { return nil }
        _ = word("ONLY")
        guard var tableName = name() else { return nil }
        var schema: String?
        if symbol(".") {
            schema = tableName
            guard let second = name() else { return nil }
            tableName = second
        }
        var method: String?
        if word("USING") { method = name()?.lowercased() }
        guard symbol("(") else { return nil }
        // Column expressions, split at top-level commas.
        let bytes = Array(sql.utf8)
        var columns: [String] = []
        var depth = 0
        var start = position < tokens.count ? tokens[position].start : bytes.count
        while position < tokens.count {
            let token = tokens[position]
            if token.kind == .symbol && token.text == "(" { depth += 1 }
            if token.kind == .symbol && (token.text == "," || token.text == ")") && depth == 0 {
                let piece = String(decoding: bytes[start..<token.start], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let unquoted = piece.hasPrefix("\"") && piece.hasSuffix("\"") && piece.count > 1 ? String(piece.dropFirst().dropLast()) : piece
                if !unquoted.isEmpty { columns.append(unquoted) }
                if token.text == ")" { break }
                start = token.end
            } else if token.kind == .symbol && token.text == ")" {
                depth -= 1
            }
            position += 1
        }
        guard !columns.isEmpty else { return nil }
        return ProposedIndex(
            table: TableRef(schema: schema, name: tableName),
            index: IndexShape(name: indexName, columns: columns, unique: unique),
            method: method,
            concurrently: concurrently
        )
    }
}
