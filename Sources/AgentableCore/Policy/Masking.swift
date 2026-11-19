import Foundation

/// Hides values of masked columns before results reach an agent.
public enum Masking {
    /// Indices of result columns to mask.
    ///
    /// A column is masked when its source is a masked table column, or when its source is unknown
    /// (an expression or alias) and the query mentions a masked column by name. The second rule is
    /// deliberately cautious: `lower(email)` or `email AS e` should not leak.
    public static func columnsToMask(
        _ columns: [ResultColumn],
        rules: VisibilityRules,
        mentioned identifiers: Set<String>
    ) -> Set<Int> {
        let masked = rules.maskedColumns.compactMap(MaskedColumn.init)
        guard !masked.isEmpty else { return [] }
        let mentionedMasked = masked.contains { identifiers.contains($0.column) }

        var indices = Set<Int>()
        for (index, column) in columns.enumerated() {
            if let table = column.sourceTable?.lowercased(), let source = column.sourceColumn?.lowercased() {
                if masked.contains(where: { $0.table == table && $0.column == source }) {
                    indices.insert(index)
                }
                continue
            }
            if mentionedMasked || masked.contains(where: { $0.column == column.name.lowercased() }) {
                indices.insert(index)
            }
        }
        return indices
    }

    public static func apply(_ result: QueryResult, masking indices: Set<Int>) -> QueryResult {
        guard !indices.isEmpty else { return result }
        var copy = result
        copy.rows = result.rows.map { row in
            row.enumerated().map { index, value in indices.contains(index) ? mask(value) : value }
        }
        return copy
    }

    public static func mask(_ value: CellValue) -> CellValue {
        switch value {
        case .null: .null
        case .text(let text): .text(maskText(text))
        default: .text("••••")
        }
    }

    /// `jane@northwind.com` → `j•••@n•••.com`, `+1 415 555 0193` → `+• ••• ••• 0193`, others keep one letter.
    public static func maskText(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        if let at = text.firstIndex(of: "@"), at != text.startIndex {
            let local = text[..<at]
            let domain = text[text.index(after: at)...]
            let tld = domain.lastIndex(of: ".").map { String(domain[$0...]) } ?? ""
            let domainHead = domain.first.map(String.init) ?? ""
            return "\(local.prefix(1))•••@\(domainHead)•••\(tld)"
        }

        let digits = text.filter(\.isNumber).count
        if digits >= 7 {
            var remaining = digits - 4
            return String(text.map { character in
                guard character.isNumber, remaining > 0 else { return character }
                remaining -= 1
                return "•"
            })
        }

        return "\(text.prefix(1))•••"
    }
}

extension VisibilityRules {
    /// The mask rules for `table.column`, as written.
    public func maskRules(table: String, column: String) -> [String] {
        maskedColumns.filter { rule in
            guard let masked = MaskedColumn(rule) else { return false }
            return masked.table == table.lowercased() && masked.column == column.lowercased()
        }
    }

    /// `rule` with its column part replaced: `public.customers.email` → `public.customers.contact`.
    public static func renamed(_ rule: String, to column: String) -> String {
        guard let dot = rule.lastIndex(of: ".") else { return rule }
        return String(rule[...dot]) + column
    }
}

private struct MaskedColumn {
    let table: String
    let column: String

    init?(_ rule: String) {
        let parts = rule.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        table = parts[parts.count - 2]
        column = parts[parts.count - 1]
    }
}
