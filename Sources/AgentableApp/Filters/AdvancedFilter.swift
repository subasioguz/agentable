import SwiftUI
import AgentableCore

/// The same filters as the chips, as condition rows: one conjunction per level, groups to mix them.
/// Edits stay a draft until Apply.
struct AdvancedFilterPanel: View {
    @Bindable var grid: GridModel
    @State private var draft = FilterGroup()
    @State private var matchCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Advanced filter").font(.ui(13, .semibold))
                Text("the same filters as the chips, as rows").foregroundStyle(Color.tmMuted)
                Spacer()
                SegmentedSwitch(
                    options: FilterText.modes,
                    selection: Binding(get: { .advanced }, set: { mode in
                        if mode == .chips && !TableFilter(root: draft).isFlat { apply() }
                        grid.filterMode = mode
                    })
                )
                .fixedSize()
            }

            GroupEditor(group: $draft, columns: grid.columns, nested: false)

            HStack(spacing: 6) {
                Button { draft.items.append(.condition(newCondition())) } label: {
                    Label("Condition", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.text)
                Button {
                    draft.items.append(.group(FilterGroup(conjunction: draft.conjunction == .and ? .or : .and, items: [.condition(newCondition())])))
                } label: {
                    Label("Group", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.text)
                Spacer()
                if let matchCount {
                    Text(matchCount == 1 ? "1 row matches" : "\(matchCount.grouped) rows match").font(.mono(12)).foregroundStyle(Color.tmMuted)
                }
                Button("Clear") { draft = FilterGroup() }.buttonStyle(.secondary)
                Button { apply() } label: {
                    HStack(spacing: 8) {
                        Text("Apply")
                        Text("↩").font(.mono(11)).opacity(0.7)
                    }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(TableFilter(root: draft) == grid.filter)
            }
            .padding(.leading, 74)

            if let sentence = FilterText.sentence(TableFilter(root: draft)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        SectionLabel(text: "Reads as")
                        Text(sentence).foregroundStyle(Color.tmText)
                    }
                    if let sql = TableFilter(root: draft).displaySQL(dialect: grid.dialect) {
                        Text("WHERE " + sql).font(.mono(11.5)).foregroundStyle(Color.tmMuted).lineLimit(2).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tmSide, in: RoundedRectangle(cornerRadius: 9))
                .padding(.leading, 82)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .onAppear {
            draft = grid.filter.root
            if draft.items.isEmpty { draft.items = [.condition(newCondition())] }
        }
        .task(id: TableFilter(root: draft)) { await countMatches() }
    }

    private func newCondition() -> FilterCondition {
        guard let column = grid.columns.first(where: { !$0.isPrimaryKey }) ?? grid.columns.first else {
            return FilterCondition(column: "", category: .text, op: .isAnyOf)
        }
        return ValuePicker.starter(for: column)
    }

    private func apply() {
        grid.filter = TableFilter(root: draft)
    }

    private func countMatches() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let browser = grid.workspace?.browser else { return }
        var query = grid.query
        query.filter = TableFilter(root: draft)
        matchCount = try? await browser.count(query, timeout: .seconds(3))
    }
}

/// One level of conditions. The first row reads "where"; the second holds the level's and/or
/// switch; later rows echo it. Top-level rows start with an on/off box.
private struct GroupEditor: View {
    @Binding var group: FilterGroup
    let columns: [GridColumn]
    let nested: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    if !nested {
                        Button {
                            toggleEnabled(at: index)
                        } label: {
                            CheckBox(on: isEnabled(item), size: 18, radius: 5)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 22, height: 34)
                        .padding(.top, item.isGroup ? 6 : 0)
                        .accessibilityLabel(isEnabled(item) ? "Switch off" : "Switch on")
                    }
                    joiner(index)
                        .frame(width: L10n.isEnglish ? 52 : 64, height: 34, alignment: .trailing)
                        .padding(.top, item.isGroup ? 4 : 0)
                    Group {
                        switch item {
                        case .condition(let condition):
                            ConditionRow(
                                condition: Binding(get: { condition }, set: { group.items[index] = .condition($0) }),
                                columns: columns,
                                nested: nested
                            ) { group.items.remove(at: index) }
                        case .group(let inner):
                            groupBox(inner, at: index)
                        }
                    }
                    .opacity(isEnabled(item) ? 1 : 0.45)
                }
            }
        }
    }

    private func groupBox(_ inner: FilterGroup, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: "Group")
                Text(inner.conjunction == .or ? "any of these" : "all of these").font(.ui(12)).foregroundStyle(Color.tmMuted)
                Spacer()
                Button("Ungroup") {
                    group.items.replaceSubrange(index...index, with: inner.items)
                }
                .buttonStyle(.text(height: 24, size: 12, color: .tmMuted))
            }
            .padding(.leading, 2)
            GroupEditor(
                group: Binding(get: { inner }, set: { group.items[index] = .group($0) }),
                columns: columns,
                nested: true
            )
            Button {
                var updated = inner
                if let first = columns.first(where: { !$0.isPrimaryKey }) ?? columns.first {
                    updated.items.append(.condition(ValuePicker.starter(for: first)))
                }
                group.items[index] = .group(updated)
            } label: {
                Label("Condition", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.text(height: 26))
            .padding(.leading, 52)
        }
        .padding(EdgeInsets(top: 10, leading: 13, bottom: 8, trailing: 6))
        .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.tmLine))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(Color.tmYou).frame(width: 3)
        }
    }

    private func isEnabled(_ item: FilterItem) -> Bool {
        switch item {
        case .condition(let condition): condition.isEnabled
        case .group(let inner): inner.isEnabled
        }
    }

    private func toggleEnabled(at index: Int) {
        switch group.items[index] {
        case .condition(var condition):
            condition.isEnabled.toggle()
            group.items[index] = .condition(condition)
        case .group(var inner):
            inner.isEnabled.toggle()
            group.items[index] = .group(inner)
        }
    }

    @ViewBuilder private func joiner(_ index: Int) -> some View {
        if index == 0 {
            Text("where").foregroundStyle(Color.tmMuted).padding(.trailing, 6)
        } else if index == 1 {
            Button {
                group.conjunction = group.conjunction == .and ? .or : .and
            } label: {
                HStack(spacing: 3) {
                    Text(FilterText.conjunction(group.conjunction)).font(.ui(12.5, .semibold))
                    IconView(.upDown, size: 11, weight: 2)
                }
                .foregroundStyle(Color.tmYou)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(Color.tmYouTint, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Switch this level between and / or")
        } else {
            Text(FilterText.conjunction(group.conjunction)).font(.ui(12.5)).foregroundStyle(Color.tmMuted).padding(.trailing, 6)
        }
    }
}

private extension FilterItem {
    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

/// Column, operator and value of one condition, as select boxes and an input.
private struct ConditionRow: View {
    @Binding var condition: FilterCondition
    let columns: [GridColumn]
    let nested: Bool
    let onRemove: () -> Void
    @State private var first = ""
    @State private var second = ""

    var body: some View {
        HStack(spacing: 8) {
            SelectBox(width: nested ? 214 : 230) {
                ForEach(columns) { column in
                    Button("\(column.name)    \(column.type)") {
                        let starter = ValuePicker.starter(for: column)
                        condition = FilterCondition(id: condition.id, column: starter.column, category: starter.category, op: starter.op, values: starter.values, isEnabled: condition.isEnabled)
                        loadFields()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(condition.column).font(.mono(12.5)).foregroundStyle(Color.tmText)
                    Text(columns.first { $0.name == condition.column }?.type ?? "").font(.mono(11.5)).foregroundStyle(Color.tmMuted)
                }
            }

            SelectBox(width: nested ? 162 : 170) {
                ForEach(condition.category.operators, id: \.self) { op in
                    Button(FilterText.row(op, condition.category)) {
                        let lists: [FilterOperator] = [.isAnyOf, .isNoneOf]
                        let keepList = lists.contains(op) && lists.contains(condition.op)
                        condition.op = op
                        if !keepList { condition.values = op == .inLast ? [.integer(7), .text("days")] : [] }
                        loadFields()
                    }
                }
            } label: {
                Text(FilterText.row(condition.op, condition.category)).font(.ui(13)).foregroundStyle(Color.tmText)
            }

            valueField
                .frame(maxWidth: .infinity)

            Button(action: onRemove) {
                IconView(.minus, size: 14)
            }
            .buttonStyle(QuietButtonStyle(size: 32))
            .accessibilityLabel("Remove condition")
        }
        .onAppear(perform: loadFields)
    }

    @ViewBuilder private var valueField: some View {
        switch condition.op {
        case .isTrue, .isFalse, .isEmpty, .isNotEmpty:
            Color.clear.frame(height: 34)
        case .isAnyOf, .isNoneOf:
            TokenField(values: $condition.values, placeholder: "Type a value, then Return", numeric: condition.category.isNumeric)
        case .inLast:
            HStack(spacing: 6) {
                InputField(placeholder: "7", text: amount).frame(width: 64)
                SelectBox(width: 110) {
                    ForEach(TimeUnit.allCases, id: \.self) { unit in
                        Button(FilterText.unit(unit)) { condition.values = [condition.values.first ?? .integer(7), .text(unit.rawValue)] }
                    }
                } label: {
                    Text(unitName).font(.ui(13)).foregroundStyle(Color.tmText)
                }
                Spacer(minLength: 0)
            }
        case .between:
            HStack(spacing: 6) {
                InputField(placeholder: "from", text: $first) { commit() }
                Text("and").foregroundStyle(Color.tmMuted)
                InputField(placeholder: "to", text: $second) { commit() }
            }
            .onChange(of: first) { commit() }
            .onChange(of: second) { commit() }
        default:
            InputField(placeholder: condition.category.isNumeric ? "100" : "value", text: $first) { commit() }
                .onChange(of: first) { commit() }
        }
    }

    private var unitName: String {
        if condition.values.count > 1, case .text(let raw) = condition.values[1] {
            return TimeUnit(rawValue: raw).map(FilterText.unit) ?? raw
        }
        return FilterText.unit(.days)
    }

    private var amount: Binding<String> {
        Binding(
            get: {
                if case .integer(let value)? = condition.values.first { return String(value) }
                return ""
            },
            set: { (text: String) in
                guard let value = Int64(text.filter(\.isNumber)) else { return }
                let unit: CellValue = condition.values.count > 1 ? condition.values[1] : .text("days")
                condition.values = [.integer(value), unit]
            }
        )
    }

    private func loadFields() {
        first = condition.values.first.map { $0.isNull ? "" : $0.displayText } ?? ""
        second = condition.values.count > 1 ? condition.values[1].displayText : ""
    }

    private func commit() {
        switch condition.op {
        case .between:
            condition.values = [first, second].filter { !$0.isEmpty }.map { .text($0) }
        case .isAnyOf, .isNoneOf, .inLast, .isTrue, .isFalse, .isEmpty, .isNotEmpty:
            break
        default:
            condition.values = first.isEmpty ? [] : [.text(first)]
        }
    }
}

/// Raw WHERE text for people who think in SQL. It runs in the read-only session like everything else.
struct WhereEditor: View {
    @Bindable var grid: GridModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            Text("WHERE").font(.mono(12.5, .semibold)).foregroundStyle(Color.tmYou)
            InputField(placeholder: "status = 'paid' AND total > 100", text: $text, height: 32) { apply() }
            Button("Clear") {
                text = ""
                grid.filter = TableFilter()
            }
            .buttonStyle(.secondary)
            Button { apply() } label: {
                HStack(spacing: 8) {
                    Text("Apply")
                    Text("↩").font(.mono(11)).opacity(0.7)
                }
            }
            .buttonStyle(.primary)
            SegmentedSwitch(
                options: FilterText.modes,
                selection: Binding(get: { .sql }, set: { mode in
                    if mode != .sql { grid.filter.whereText = nil }
                    grid.filterMode = mode
                })
            )
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .onAppear {
            text = grid.filter.usesWhereText ? (grid.filter.whereText ?? "") : (grid.filter.displaySQL(dialect: grid.dialect) ?? "")
        }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var filter = grid.filter
        filter.whereText = trimmed.isEmpty ? nil : trimmed
        if trimmed.isEmpty { filter.root = FilterGroup() }
        grid.filter = filter
    }
}
