import Foundation

/// One value in a result set.
public enum CellValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case bool(Bool)

    /// How the value reads in a grid or in agent output.
    public var displayText: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let value):
            return String(value)
        case .real(let value):
            return value.rounded() == value && abs(value) < 1e15 ? String(format: "%.1f", value) : String(value)
        case .text(let value):
            return value
        case .blob(let data):
            let shown = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            return "x'\(shown)\(data.count > 16 ? "…" : "")' (\(data.count) bytes)"
        case .bool(let value):
            return value ? "true" : "false"
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension CellValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .integer(let value): try container.encode(value)
        case .real(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        case .blob(let data): try container.encode("base64:" + data.base64EncodedString())
        case .bool(let value): try container.encode(value)
        }
    }
}

/// A result column and, when the engine can tell, the table column it came from.
public struct ResultColumn: Sendable, Hashable, Codable {
    public var name: String
    public var typeName: String?
    public var sourceTable: String?
    public var sourceColumn: String?

    public init(name: String, typeName: String? = nil, sourceTable: String? = nil, sourceColumn: String? = nil) {
        self.name = name
        self.typeName = typeName
        self.sourceTable = sourceTable
        self.sourceColumn = sourceColumn
    }
}

public struct QueryResult: Sendable {
    public var columns: [ResultColumn]
    public var rows: [[CellValue]]
    /// More rows existed than `QueryOptions.maxRows`.
    public var truncated: Bool
    /// Rows changed by a write; `nil` for reads.
    public var rowsAffected: Int?
    public var elapsed: Duration

    public init(
        columns: [ResultColumn],
        rows: [[CellValue]],
        truncated: Bool = false,
        rowsAffected: Int? = nil,
        elapsed: Duration = .zero
    ) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
        self.rowsAffected = rowsAffected
        self.elapsed = elapsed
    }

    public var elapsedMilliseconds: Double {
        let parts = elapsed.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

public struct QueryOptions: Sendable {
    /// The engine must refuse anything that writes.
    public var readOnly: Bool
    public var maxRows: Int
    public var timeout: Duration

    public init(readOnly: Bool, maxRows: Int, timeout: Duration) {
        self.readOnly = readOnly
        self.maxRows = maxRows
        self.timeout = timeout
    }
}
