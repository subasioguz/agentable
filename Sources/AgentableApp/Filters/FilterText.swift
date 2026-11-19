import Foundation
import AgentableCore

/// Filters as people read them, in the interface language. AgentableCore has English versions of
/// these (`FilterCondition.valueLabel`, `TableFilter.sentence`) for the CLI; the app shows these.
enum FilterText {
    /// The chips / advanced / WHERE switch.
    static var modes: [(value: FilterMode, label: String)] {
        [(.chips, String(localized: "Chips")), (.advanced, String(localized: "Advanced")), (.sql, "WHERE")]
    }

    /// The short operator a chip and the operator track show: "is", "contains", ">".
    static func chip(_ op: FilterOperator, _ category: ColumnCategory) -> String {
        L10n.core(op.chipLabel(category))
    }

    /// The shortest operator, for segments: "empty", "last".
    static func segment(_ op: FilterOperator, _ category: ColumnCategory) -> String {
        L10n.core(op.segmentLabel(category))
    }

    /// The long operator condition rows show: "is any of", "is within the last".
    static func row(_ op: FilterOperator, _ category: ColumnCategory) -> String {
        L10n.core(op.rowLabel(category))
    }

    /// "and", "or".
    static func conjunction(_ conjunction: Conjunction) -> String {
        switch conjunction {
        case .and: String(localized: "and")
        case .or: String(localized: "or")
        }
    }

    /// A time unit's name, as the unit choices show it: "days".
    static func unit(_ unit: TimeUnit) -> String {
        switch unit {
        case .minutes: String(localized: "minutes")
        case .hours: String(localized: "hours")
        case .days: String(localized: "days")
        case .weeks: String(localized: "weeks")
        case .months: String(localized: "months")
        }
    }

    /// "7 days", "1 hour".
    static func span(_ amount: Int64, _ raw: String) -> String {
        guard let unit = TimeUnit(rawValue: raw) else { return "\(amount) \(raw)" }
        if amount == 1 {
            switch unit {
            case .minutes: return String(localized: "1 minute")
            case .hours: return String(localized: "1 hour")
            case .days: return String(localized: "1 day")
            case .weeks: return String(localized: "1 week")
            case .months: return String(localized: "1 month")
            }
        }
        switch unit {
        case .minutes: return String(localized: "\(amount) minutes")
        case .hours: return String(localized: "\(amount) hours")
        case .days: return String(localized: "\(amount) days")
        case .weeks: return String(localized: "\(amount) weeks")
        case .months: return String(localized: "\(amount) months")
        }
    }

    /// One value as filters show it; NULL reads "empty".
    static func value(_ value: CellValue) -> String {
        value.isNull ? String(localized: "empty") : value.displayText
    }

    /// What a chip shows after the operator: "paid, shipped", "7 days", "10 – 20".
    static func valueLabel(_ condition: FilterCondition) -> String {
        let values = condition.values
        switch condition.op {
        case .isTrue: return String(localized: "true")
        case .isFalse: return String(localized: "false")
        case .isEmpty, .isNotEmpty: return ""
        case .between:
            guard values.count == 2 else { return "…" }
            return "\(value(values[0])) – \(value(values[1]))"
        case .inLast:
            guard values.count == 2, case .integer(let amount) = values[0], case .text(let unit) = values[1] else { return "…" }
            return span(amount, unit)
        case .isAnyOf, .isNoneOf:
            guard !values.isEmpty else { return "…" }
            let shown = values.prefix(3).map(value).joined(separator: ", ")
            return values.count > 3 ? "\(shown) +\(values.count - 3)" : shown
        default:
            return values.first.map(value) ?? "…"
        }
    }

    /// "status is paid or shipped"
    static func sentence(_ condition: FilterCondition) -> String {
        let column = condition.column
        let op = chip(condition.op, condition.category)
        switch condition.op {
        case .isAnyOf, .isNoneOf:
            let list = condition.values.map(value)
            let joined = list.count > 1
                ? String(localized: "\(list.dropLast().joined(separator: ", ")) or \(list.last!)")
                : (list.first ?? "…")
            return "\(column) \(op) \(joined)"
        case .isEmpty, .isNotEmpty:
            return "\(column) \(op)"
        default:
            return "\(column) \(op) \(valueLabel(condition))"
        }
    }

    /// The group's switched-on conditions joined by its and/or; `nil` when none is on.
    static func sentence(_ group: FilterGroup) -> String? {
        guard group.isEnabled else { return nil }
        let parts = group.items.compactMap { item -> String? in
            switch item {
            case .condition(let condition): condition.isActive ? sentence(condition) : nil
            case .group(let inner): sentence(inner).map { "(\($0))" }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \(conjunction(group.conjunction)) ")
    }

    /// "created_at in the last 7 days and status is paid or shipped"; typed WHERE text as typed.
    static func sentence(_ filter: TableFilter) -> String? {
        filter.usesWhereText ? filter.whereText : sentence(filter.root)
    }
}
