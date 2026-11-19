import Foundation

/// How a person left a table: sort, column order, hidden columns and widths, remembered per
/// connection and table. Filters and search are not part of it.
public struct TableLayout: Codable, Sendable, Equatable {
    /// `nil` until the person picks a sort; then the default order applies.
    public var sort: [SortKey]?
    public var order: [String]
    public var hidden: [String]
    /// Only widths the person changed.
    public var widths: [String: Double]

    public init(sort: [SortKey]? = nil, order: [String] = [], hidden: [String] = [], widths: [String: Double] = [:]) {
        self.sort = sort
        self.order = order
        self.hidden = hidden
        self.widths = widths
    }

    /// The table's columns in the remembered order. Columns that are gone are dropped; columns
    /// added since keep their place in the table's own order, after the remembered ones.
    public func ordered(_ columns: [String]) -> [String] {
        let present = Set(columns)
        let remembered = order.filter { present.contains($0) }
        let known = Set(remembered)
        return remembered + columns.filter { !known.contains($0) }
    }

    /// Hidden columns that still exist, leaving at least one column visible.
    public func hiddenColumns(_ columns: [String]) -> Set<String> {
        let hidden = Set(self.hidden).intersection(columns)
        return hidden.count >= columns.count ? [] : hidden
    }

    /// The remembered sort without columns that are gone, or `nil` to use the default order.
    public func sortKeys(_ columns: [String]) -> [SortKey]? {
        let present = Set(columns)
        return sort.map { $0.filter { present.contains($0.column) } }
    }

    /// Whether this is just the table as it comes: nothing to remember.
    public func isDefault(columns: [String]) -> Bool {
        sort == nil && hidden.isEmpty && widths.isEmpty && ordered(columns) == columns
    }
}

/// The order tables open in until their sort is changed: by primary key, oldest or newest first.
public enum DefaultOrder: String, Codable, CaseIterable, Sendable {
    case oldestFirst, newestFirst

    public var title: String {
        switch self {
        case .oldestFirst: "Oldest first"
        case .newestFirst: "Newest first"
        }
    }

    public func sort(primaryKey: [String]) -> [SortKey] {
        primaryKey.map { SortKey(column: $0, ascending: self == .oldestFirst) }
    }
}
