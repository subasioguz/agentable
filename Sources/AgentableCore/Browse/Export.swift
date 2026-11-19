import Foundation

/// Text formats rows can be copied or exported as.
public enum ExportFormat: String, CaseIterable, Sendable {
    case csv, json, sqlInsert, markdown

    public var title: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .sqlInsert: "SQL INSERT"
        case .markdown: "Markdown"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .json: "json"
        case .sqlInsert: "sql"
        case .markdown: "md"
        }
    }
}

/// A column as it is exported: its name and what kind of values it holds.
public struct ExportColumn: Sendable, Hashable {
    public var name: String
    public var category: ColumnCategory
    /// Digits after the point for `numeric(p,s)` columns: both engines hand back 129 for 129.00.
    public var scale: Int?

    public init(name: String, category: ColumnCategory, scale: Int? = nil) {
        self.name = name
        self.category = category
        self.scale = scale
    }

    /// The value with the column's scale, when it is a number that lost it.
    func fixed(_ value: CellValue) -> CellValue {
        guard let scale, category == .decimal else { return value }
        let decimal: Decimal? = switch value {
        case .integer(let number): Decimal(number)
        case .real(let number) where number.isFinite: Decimal(number)
        case .text(let text): Decimal(string: text, locale: Self.posix)
        default: nil
        }
        guard var exact = decimal else { return value }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, scale, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Self.posix
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = scale
        formatter.maximumFractionDigits = scale
        return formatter.string(from: rounded as NSDecimalNumber).map { .text($0) } ?? value
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
}

/// Turns rows into text a chunk at a time, so a large export can stream to disk:
/// `header()`, then `rows(_:)` for each page, then `footer()`.
///
/// Values are written as stored: NULL is an empty CSV field, `null` in JSON, `NULL` in SQL and an
/// empty Markdown cell. JSON keeps numbers and booleans typed and embeds JSON columns as JSON.
public struct RowWriter: Sendable {
    public let format: ExportFormat
    public let columns: [ExportColumn]
    public let table: TableRef
    public let dialect: SQLDialect
    public private(set) var rowsWritten = 0

    public init(format: ExportFormat, columns: [ExportColumn], table: TableRef, dialect: SQLDialect) {
        self.format = format
        self.columns = columns
        self.table = table
        self.dialect = dialect
    }

    /// Writes all rows at once, for the clipboard.
    public static func text(_ format: ExportFormat, columns: [ExportColumn], rows: [[CellValue]], table: TableRef, dialect: SQLDialect) -> String {
        var writer = RowWriter(format: format, columns: columns, table: table, dialect: dialect)
        return writer.header() + writer.rows(rows) + writer.footer()
    }

    public func header() -> String {
        switch format {
        case .csv:
            return columns.map { Self.csvField($0.name) }.joined(separator: ",") + "\n"
        case .json:
            return "["
        case .sqlInsert:
            return ""
        case .markdown:
            let names = columns.map { Self.markdownCell($0.name) }
            let rule = columns.map { $0.category.isNumeric ? "---:" : "---" }
            return "| " + names.joined(separator: " | ") + " |\n| " + rule.joined(separator: " | ") + " |\n"
        }
    }

    /// Each row holds one value per column, in column order.
    public mutating func rows(_ rows: [[CellValue]]) -> String {
        var text = ""
        for original in rows {
            let row = zip(columns, original).map { $0.fixed($1) }
            switch format {
            case .csv:
                text += zip(columns, row).map { Self.csvField(Self.plain($1)) }.joined(separator: ",") + "\n"
            case .json:
                let fields = zip(columns, row).map { Self.jsonString($0.name) + ": " + Self.json($1, category: $0.category) }
                text += (rowsWritten == 0 ? "\n  {" : ",\n  {") + fields.joined(separator: ", ") + "}"
            case .sqlInsert:
                let names = columns.map { SQLBuilder.quote($0.name) }.joined(separator: ", ")
                let values = row.prefix(columns.count).map { literal($0) }.joined(separator: ", ")
                text += "INSERT INTO \(table.sql) (\(names)) VALUES (\(values));\n"
            case .markdown:
                text += "| " + row.prefix(columns.count).map { Self.markdownCell(Self.plain($0, null: "")) }.joined(separator: " | ") + " |\n"
            }
            rowsWritten += 1
        }
        return text
    }

    public func footer() -> String {
        guard format == .json else { return "" }
        return rowsWritten == 0 ? "]\n" : "\n]\n"
    }

    // MARK: Values

    /// The value as plain text; binary data as `\x` hex.
    static func plain(_ value: CellValue, null: String = "") -> String {
        switch value {
        case .null: null
        case .integer(let number): String(number)
        case .real(let number): Self.real(number)
        case .text(let text): text
        case .blob(let data): "\\x" + data.map { String(format: "%02x", $0) }.joined()
        case .bool(let flag): flag ? "true" : "false"
        }
    }

    static func real(_ number: Double) -> String {
        if number.isFinite, number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }

    static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || text.hasPrefix(" ") || text.hasSuffix(" ") else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func markdownCell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    static func json(_ value: CellValue, category: ColumnCategory) -> String {
        switch value {
        case .null:
            return "null"
        case .integer(let number):
            return String(number)
        case .real(let number):
            return number.isFinite ? Self.real(number) : "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .blob:
            return jsonString(plain(value))
        case .text(let text):
            switch category {
            case .integer, .decimal:
                if isJSONNumber(text) { return text }
            case .boolean:
                switch text.lowercased() {
                case "t", "true": return "true"
                case "f", "false": return "false"
                default: break
                }
            case .json:
                if let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                    return text
                }
            default:
                break
            }
            return jsonString(text)
        }
    }

    static func isJSONNumber(_ text: String) -> Bool {
        text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar == "\u{2028}" || scalar == "\u{2029}":
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A literal that both engines read back as the same value.
    func literal(_ value: CellValue) -> String {
        if case .blob(let data) = value, dialect == .postgres {
            return "'\\x" + data.map { String(format: "%02x", $0) }.joined() + "'::bytea"
        }
        if case .real(let number) = value {
            return number.isFinite ? Self.real(number) : "'\(number)'"
        }
        return SQLBuilder.literal(value)
    }
}

extension TableBrowser {
    /// Writes every row of a view to a file, a page at a time in the view's order, on the person's
    /// read-only session. Returns how many rows were written. Calls `progress` after each page.
    public func export(
        _ query: TableQuery,
        columns: [ExportColumn],
        format: ExportFormat,
        to url: URL,
        pageSize: Int = 5_000,
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> Int {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DatabaseError.unsupported("Could not create \(url.lastPathComponent).")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var writer = RowWriter(format: format, columns: columns, table: query.table, dialect: engine.sqlDialect)
        try handle.write(contentsOf: Data(writer.header().utf8))
        var offset = 0
        while true {
            try Task.checkCancellation()
            let result = try await page(query, offset: offset, limit: pageSize)
            let rows = Self.project(result, onto: columns.map(\.name))
            try handle.write(contentsOf: Data(writer.rows(rows).utf8))
            offset += result.rows.count
            progress(offset)
            if result.rows.count < pageSize { break }
        }
        try handle.write(contentsOf: Data(writer.footer().utf8))
        return writer.rowsWritten
    }

    /// The result's rows with values in the order of `names`; a missing column reads as NULL.
    public static func project(_ result: QueryResult, onto names: [String]) -> [[CellValue]] {
        let index = Dictionary(result.columns.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
        let positions = names.map { index[$0] }
        return result.rows.map { row in
            positions.map { position in position.flatMap { $0 < row.count ? row[$0] : nil } ?? .null }
        }
    }
}
