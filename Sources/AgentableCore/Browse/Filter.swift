import Foundation

/// The broad kind of a column, from its declared type. Drives which filters and editors fit.
public enum ColumnCategory: Sendable, Hashable {
    case text, integer, decimal, dateTime, date, boolean, binary, json, other

    public init(typeName: String) {
        let type = typeName.lowercased()
        if type.contains("bool") {
            self = .boolean
        } else if type.contains("int") || type.contains("serial") {
            self = .integer
        } else if ["numeric", "decimal", "real", "double", "float", "money"].contains(where: type.contains) {
            self = .decimal
        } else if type.contains("timestamp") || type.contains("datetime") {
            self = .dateTime
        } else if type == "date" {
            self = .date
        } else if type.contains("json") {
            self = .json
        } else if type.contains("bytea") || type.contains("blob") {
            self = .binary
        } else if type.isEmpty || ["char", "text", "uuid", "clob", "citext", "name"].contains(where: type.contains) {
            self = .text
        } else {
            self = .other
        }
    }

    public var isNumeric: Bool { self == .integer || self == .decimal }
    public var isTemporal: Bool { self == .dateTime || self == .date }

    /// The four operators a value picker shows as segments; the rest go under "More".
    public var pickerOperators: [FilterOperator] {
        switch self {
        case .integer, .decimal: [.isAnyOf, .greaterThan, .lessThan, .between]
        case .dateTime, .date: [.inLast, .before, .after, .between]
        case .boolean: [.isTrue, .isFalse, .isEmpty]
        case .binary: [.isEmpty, .isNotEmpty]
        case .text, .json, .other: [.isAnyOf, .isNoneOf, .contains, .isEmpty]
        }
    }

    /// Operators offered for this kind of column, most useful first.
    public var operators: [FilterOperator] {
        switch self {
        case .integer, .decimal:
            [.isAnyOf, .isNoneOf, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between, .isEmpty, .isNotEmpty]
        case .dateTime, .date:
            [.inLast, .before, .after, .between, .isEmpty, .isNotEmpty]
        case .boolean:
            [.isTrue, .isFalse, .isEmpty, .isNotEmpty]
        case .binary:
            [.isEmpty, .isNotEmpty]
        case .text, .json, .other:
            [.isAnyOf, .isNoneOf, .contains, .doesNotContain, .startsWith, .isEmpty, .isNotEmpty]
        }
    }
}

public enum FilterOperator: String, Sendable, Hashable, CaseIterable {
    case isAnyOf, isNoneOf, contains, doesNotContain, startsWith
    case greaterThan, greaterOrEqual, lessThan, lessOrEqual, between
    case inLast, before, after
    case isTrue, isFalse
    case isEmpty, isNotEmpty

    /// How many values the operator takes: `nil` for a list.
    public var arity: Int? {
        switch self {
        case .isAnyOf, .isNoneOf: nil
        case .between, .inLast: 2
        case .isTrue, .isFalse, .isEmpty, .isNotEmpty: 0
        default: 1
        }
    }

    /// The short form a chip shows.
    public func chipLabel(_ category: ColumnCategory) -> String {
        switch self {
        case .isAnyOf: category.isNumeric ? "=" : "is"
        case .isNoneOf: category.isNumeric ? "≠" : "is not"
        case .contains: "contains"
        case .doesNotContain: "doesn't contain"
        case .startsWith: "starts with"
        case .greaterThan: ">"
        case .greaterOrEqual: "≥"
        case .lessThan: "<"
        case .lessOrEqual: "≤"
        case .between: "between"
        case .inLast: "in the last"
        case .before: "before"
        case .after: "after"
        case .isTrue, .isFalse: "is"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        }
    }

    /// The shortest form, for segmented controls.
    public func segmentLabel(_ category: ColumnCategory) -> String {
        switch self {
        case .isEmpty: "empty"
        case .isNotEmpty: "not empty"
        case .isTrue: "true"
        case .isFalse: "false"
        case .inLast: "last"
        default: chipLabel(category)
        }
    }

    /// The long form condition rows show.
    public func rowLabel(_ category: ColumnCategory) -> String {
        switch self {
        case .isAnyOf: category.isNumeric ? "equals" : "is any of"
        case .isNoneOf: category.isNumeric ? "does not equal" : "is none of"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .startsWith: "starts with"
        case .greaterThan: "is greater than"
        case .greaterOrEqual: "is at least"
        case .lessThan: "is less than"
        case .lessOrEqual: "is at most"
        case .between: "is between"
        case .inLast: "is within the last"
        case .before: "is before"
        case .after: "is after"
        case .isTrue: "is true"
        case .isFalse: "is false"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        }
    }
}

public enum TimeUnit: String, Sendable, Hashable, CaseIterable {
    case minutes, hours, days, weeks, months

    func postgresInterval(_ amount: Int64) -> String { "\(amount) \(rawValue)" }

    /// A `datetime('now', …)` modifier; SQLite has no weeks.
    func sqliteModifier(_ amount: Int64) -> String {
        self == .weeks ? "-\(amount * 7) days" : "-\(amount) \(rawValue)"
    }
}

/// One condition on one column.
public struct FilterCondition: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var column: String
    public var category: ColumnCategory
    public var op: FilterOperator
    /// Values the operator compares with. `inLast` takes an integer and a `TimeUnit` raw value.
    public var values: [CellValue]
    /// Switched off conditions stay in the list but do not filter.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), column: String, category: ColumnCategory, op: FilterOperator, values: [CellValue] = [], isEnabled: Bool = true) {
        self.id = id
        self.column = column
        self.category = category
        self.op = op
        self.values = values
        self.isEnabled = isEnabled
    }

    /// Takes part in the query: switched on and complete.
    public var isActive: Bool { isEnabled && isComplete }

    /// Has what its operator needs, so it takes part in the query.
    public var isComplete: Bool {
        switch op.arity {
        case nil: !values.isEmpty
        case 0: true
        case let count?: values.count >= count && !values.prefix(count).contains(.null)
        }
    }

    // MARK: Text for people

    public var valueLabel: String {
        switch op {
        case .isTrue: return "true"
        case .isFalse: return "false"
        case .isEmpty, .isNotEmpty: return ""
        case .between:
            guard values.count == 2 else { return "…" }
            return "\(Self.label(values[0])) – \(Self.label(values[1]))"
        case .inLast:
            guard values.count == 2, case .integer(let amount) = values[0], case .text(let unit) = values[1] else { return "…" }
            return "\(amount) \(amount == 1 ? String(unit.dropLast()) : unit)"
        case .isAnyOf, .isNoneOf:
            guard !values.isEmpty else { return "…" }
            let shown = values.prefix(3).map(Self.label).joined(separator: ", ")
            return values.count > 3 ? "\(shown) +\(values.count - 3)" : shown
        default:
            return values.first.map(Self.label) ?? "…"
        }
    }

    /// "status is paid or shipped"
    public var sentence: String {
        switch op {
        case .isAnyOf, .isNoneOf:
            let list = values.map(Self.label)
            let joined = list.count > 1 ? list.dropLast().joined(separator: ", ") + " or " + list.last! : (list.first ?? "…")
            return "\(column) \(op.chipLabel(category)) \(joined)"
        case .isEmpty, .isNotEmpty:
            return "\(column) \(op.chipLabel(category))"
        default:
            return "\(column) \(op.chipLabel(category)) \(valueLabel)"
        }
    }

    static func label(_ value: CellValue) -> String {
        value.isNull ? "empty" : value.displayText
    }

    // MARK: SQL

    func sql(_ builder: inout SQLBuilder) -> String? {
        guard isActive else { return nil }
        let c = SQLBuilder.quote(column)
        let asText = "CAST(\(c) AS \(builder.dialect == .postgres ? "text" : "TEXT"))"
        let like = builder.dialect == .postgres ? "ILIKE" : "LIKE"

        switch op {
        case .isAnyOf, .isNoneOf:
            let present = values.filter { !$0.isNull }
            let wantsNull = values.contains(.null)
            var list = ""
            if !present.isEmpty {
                list = present.map { builder.value($0) }.joined(separator: ", ")
            }
            if op == .isAnyOf {
                var parts: [String] = []
                if !present.isEmpty { parts.append(present.count == 1 ? "\(c) = \(list)" : "\(c) IN (\(list))") }
                if wantsNull { parts.append("\(c) IS NULL") }
                return parts.count == 1 ? parts[0] : "(\(parts.joined(separator: " OR ")))"
            } else {
                let notIn = present.count == 1 ? "\(c) <> \(list)" : "\(c) NOT IN (\(list))"
                if wantsNull {
                    return present.isEmpty ? "\(c) IS NOT NULL" : "(\(notIn) AND \(c) IS NOT NULL)"
                }
                return "(\(notIn) OR \(c) IS NULL)"
            }
        case .contains, .doesNotContain, .startsWith:
            let needle = Self.escapeLike(values[0].isNull ? "" : values[0].displayText)
            let pattern = op == .startsWith ? "\(needle)%" : "%\(needle)%"
            let test = "\(asText) \(op == .doesNotContain ? "NOT " : "")\(like) \(builder.value(.text(pattern))) ESCAPE '\\'"
            return op == .doesNotContain ? "(\(test) OR \(c) IS NULL)" : test
        case .greaterThan, .after:
            return "\(c) > \(builder.value(values[0]))"
        case .greaterOrEqual:
            return "\(c) >= \(builder.value(values[0]))"
        case .lessThan, .before:
            return "\(c) < \(builder.value(values[0]))"
        case .lessOrEqual:
            return "\(c) <= \(builder.value(values[0]))"
        case .between:
            return "\(c) BETWEEN \(builder.value(values[0])) AND \(builder.value(values[1]))"
        case .inLast:
            guard case .integer(let amount) = values[0], case .text(let raw) = values[1], let unit = TimeUnit(rawValue: raw) else {
                return nil
            }
            if builder.dialect == .postgres {
                return "\(c) >= now() - CAST(\(builder.value(.text(unit.postgresInterval(amount)))) AS interval)"
            }
            return "\(c) >= datetime('now', \(builder.value(.text(unit.sqliteModifier(amount)))))"
        case .isTrue:
            return "\(c) IS TRUE"
        case .isFalse:
            return "\(c) IS FALSE"
        case .isEmpty:
            return category == .text ? "(\(c) IS NULL OR \(asText) = '')" : "\(c) IS NULL"
        case .isNotEmpty:
            return category == .text ? "(\(c) IS NOT NULL AND \(asText) <> '')" : "\(c) IS NOT NULL"
        }
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

public enum Conjunction: String, Sendable, Hashable {
    case and, or

    var sql: String { self == .and ? "AND" : "OR" }
}

/// Conditions joined by one conjunction. Mixing `and` and `or` takes a nested group.
public struct FilterGroup: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var conjunction: Conjunction
    public var items: [FilterItem]
    /// A switched off group stays in the list but does not filter.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), conjunction: Conjunction = .and, items: [FilterItem] = [], isEnabled: Bool = true) {
        self.id = id
        self.conjunction = conjunction
        self.items = items
        self.isEnabled = isEnabled
    }

    /// Conditions that take part in the query, skipping switched off groups.
    public var activeConditions: [FilterCondition] {
        guard isEnabled else { return [] }
        return items.flatMap { item -> [FilterCondition] in
            switch item {
            case .condition(let condition): condition.isActive ? [condition] : []
            case .group(let group): group.activeConditions
            }
        }
    }

    /// Every condition in the group and its subgroups.
    public var conditions: [FilterCondition] {
        items.flatMap { item -> [FilterCondition] in
            switch item {
            case .condition(let condition): [condition]
            case .group(let group): group.conditions
            }
        }
    }

    func sql(_ builder: inout SQLBuilder, excluding: UUID?) -> String? {
        guard isEnabled else { return nil }
        let parts = items.compactMap { item -> String? in
            switch item {
            case .condition(let condition):
                return condition.id == excluding ? nil : condition.sql(&builder)
            case .group(let group):
                return group.sql(&builder, excluding: excluding).map { "(\($0))" }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \(conjunction.sql) ")
    }

    var sentence: String? {
        guard isEnabled else { return nil }
        let parts = items.compactMap { item -> String? in
            switch item {
            case .condition(let condition): condition.isActive ? condition.sentence : nil
            case .group(let group): group.sentence.map { "(\($0))" }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \(conjunction.rawValue) ")
    }
}

public enum FilterItem: Sendable, Hashable, Identifiable {
    case condition(FilterCondition)
    case group(FilterGroup)

    public var id: UUID {
        switch self {
        case .condition(let condition): condition.id
        case .group(let group): group.id
        }
    }
}

/// What a table view filters on: condition rows (chips are the flat `and` case) or, in WHERE
/// mode, the person's own condition text.
public struct TableFilter: Sendable, Hashable {
    public var root: FilterGroup
    /// The person's own `WHERE` text. When set it replaces `root`.
    public var whereText: String?

    public init(root: FilterGroup = FilterGroup(), whereText: String? = nil) {
        self.root = root
        self.whereText = whereText
    }

    public var usesWhereText: Bool {
        !(whereText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public var isEmpty: Bool {
        !usesWhereText && root.activeConditions.isEmpty
    }

    /// Only `and`-joined conditions: what chips can show.
    public var isFlat: Bool {
        !usesWhereText && (root.conjunction == .and || root.items.count < 2) && root.items.allSatisfy {
            if case .condition = $0 { return true }
            return false
        }
    }

    public var conditions: [FilterCondition] { root.conditions }

    public var filteredColumns: Set<String> {
        Set(root.activeConditions.map(\.column))
    }

    /// The condition, without `WHERE`; `nil` when nothing filters. `excluding` leaves one condition
    /// out, for counting the values that condition picks from.
    public func sql(_ builder: inout SQLBuilder, excluding: UUID? = nil) -> String? {
        if usesWhereText, let whereText {
            return "(\(whereText.trimmingCharacters(in: .whitespacesAndNewlines)))"
        }
        return root.sql(&builder, excluding: excluding)
    }

    /// The condition with values written out, for showing and for starting a WHERE edit.
    public func displaySQL(dialect: SQLDialect) -> String? {
        var builder = SQLBuilder(dialect: dialect, inline: true)
        return sql(&builder)
    }

    /// "created_at in the last 7 days and status is paid or shipped"
    public var sentence: String? {
        usesWhereText ? whereText : root.sentence
    }

    public mutating func append(_ condition: FilterCondition) {
        root.items.append(.condition(condition))
    }

    public mutating func remove(_ id: UUID) {
        root = Self.removing(id, from: root)
    }

    public mutating func update(_ condition: FilterCondition) {
        root = Self.replacing(condition, in: root)
    }

    static func removing(_ id: UUID, from group: FilterGroup) -> FilterGroup {
        var copy = group
        copy.items = group.items.compactMap { item in
            switch item {
            case .condition(let condition):
                return condition.id == id ? nil : item
            case .group(let inner):
                if inner.id == id { return nil }
                let pruned = removing(id, from: inner)
                return pruned.items.isEmpty ? nil : .group(pruned)
            }
        }
        return copy
    }

    static func replacing(_ condition: FilterCondition, in group: FilterGroup) -> FilterGroup {
        var copy = group
        copy.items = group.items.map { item in
            switch item {
            case .condition(let existing): existing.id == condition.id ? .condition(condition) : item
            case .group(let inner): .group(replacing(condition, in: inner))
            }
        }
        return copy
    }
}
