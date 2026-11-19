import SwiftUI
import AgentableCore

/// Edits one chip, as in the design: the column and its type, one operator track, then either
/// the column's values with how many rows have each, or a field. Changes apply as you click.
///
/// Columns where every value is different (keys, ids, emails) get a field to type or paste values
/// instead of a list of ones.
struct ValuePicker: View {
    @Bindable var grid: GridModel
    let condition: FilterCondition
    let onDone: () -> Void

    @State private var search = ""
    @State private var counts: [ValueCount] = []
    @State private var loading = true
    /// The loaded values were all distinct, so a list would not help.
    @State private var allDistinct = false
    @State private var first = ""
    @State private var second = ""
    @State private var typed = ""
    @FocusState private var focused: Bool

    /// A new condition with the operator that suits the column best.
    static func starter(for column: GridColumn) -> FilterCondition {
        let op: FilterOperator = switch column.category {
        case .dateTime, .date: .inLast
        case .integer, .decimal: column.isPrimaryKey || column.foreignTable != nil ? .isAnyOf : .greaterThan
        case .boolean: .isTrue
        case .binary: .isNotEmpty
        default: .isAnyOf
        }
        return FilterCondition(column: column.name, category: column.category, op: op, values: op == .inLast ? [.integer(7), .text("days")] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(condition.column).font(.mono(13, .semibold)).foregroundStyle(Color.tmText)
                Text(subtitle).font(.ui(12)).foregroundStyle(Color.tmMuted)
            }
            operatorTrack
            content
            HStack(spacing: 8) {
                Text(footnote).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(2)
                Spacer(minLength: 8)
                Button("Done", action: onDone).buttonStyle(.secondary(height: 28)).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Hairline(color: .tmLine2) }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear(perform: loadFields)
        .task(id: "\(condition.op.rawValue)|\(search)") { await loadCounts() }
    }

    private var column: GridColumn? { grid.columns.first { $0.name == condition.column } }

    private var usesList: Bool { condition.op == .isAnyOf || condition.op == .isNoneOf }

    /// Type values instead of picking them: primary keys, and columns whose values are all different.
    private var typesValues: Bool { usesList && (column?.isPrimaryKey == true || allDistinct) }

    private var subtitle: String {
        let type = column?.type ?? ""
        guard usesList, !loading, !typesValues else { return type }
        if counts.count >= 50 { return String(localized: "\(type) · 50+ values") }
        return counts.count == 1 ? String(localized: "\(type) · 1 distinct value") : String(localized: "\(type) · \(counts.count) distinct values")
    }

    private var footnote: String {
        if typesValues { return String(localized: "Press Return to add") }
        if usesList {
            return grid.filter.conditions.count > 1 ? String(localized: "Counted under your other filters") : String(localized: "Applies as you click")
        }
        if condition.op.arity == 0 { return String(localized: "Applies right away") }
        return String(localized: "Press Return to apply")
    }

    // MARK: Operator

    /// Four segments in one track, as drawn; rarer operators sit behind the last one.
    private var operatorTrack: some View {
        let shown = condition.category.pickerOperators
        let more = condition.category.operators.filter { !shown.contains($0) }
        let moreSelected = !shown.contains(condition.op)
        return HStack(spacing: 2) {
            ForEach(shown, id: \.self) { op in
                Button {
                    change(to: op)
                } label: {
                    segment(FilterText.segment(op, condition.category), selected: condition.op == op)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(condition.op == op ? .isSelected : [])
            }
            if !more.isEmpty {
                Menu {
                    ForEach(more, id: \.self) { op in
                        Button(FilterText.row(op, condition.category)) { change(to: op) }
                    }
                } label: {
                    if moreSelected {
                        segment(FilterText.segment(condition.op, condition.category), selected: true)
                    } else {
                        IconView(.more, size: 14)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.tmText2)
                            .frame(width: 30, height: 26)
                            .contentShape(Rectangle())
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More operators")
                .accessibilityLabel("More operators")
            }
        }
        .padding(3)
        .background(Color.tmChip, in: RoundedRectangle(cornerRadius: 8))
    }

    private func segment(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(.ui(12.5, selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.tmText : Color.tmText2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6).fill(Color.tmWindow).shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
    }

    private func change(to op: FilterOperator) {
        var updated = condition
        guard op != updated.op else { return }
        let keepList = (op == .isAnyOf || op == .isNoneOf) && usesList
        updated.op = op
        if !keepList {
            updated.values = op == .inLast ? [.integer(7), .text("days")] : []
        }
        grid.filter.update(updated)
        first = ""
        second = ""
        loadFields()
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch condition.op {
        case .isAnyOf, .isNoneOf:
            if typesValues { typedValues } else { valueList }
        case .between:
            HStack(spacing: 8) {
                textField("from", text: $first)
                Text("and").foregroundStyle(Color.tmMuted)
                textField("to", text: $second)
            }
        case .inLast:
            lastWindow
        case .isTrue, .isFalse, .isEmpty, .isNotEmpty:
            EmptyView()
        default:
            textField(placeholder, text: $first)
        }
    }

    private var placeholder: LocalizedStringKey {
        switch condition.category {
        case .dateTime: "2026-11-18 09:00"
        case .date: "2026-11-18"
        case .integer, .decimal: "100"
        default: "text"
        }
    }

    private func textField(_ placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        FieldBox(height: 32) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.mono(12.5))
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit(commitFields)
        }
    }

    private var lastWindow: some View {
        let amount = Binding<String>(
            get: {
                if case .integer(let value)? = condition.values.first { return String(value) }
                return ""
            },
            set: { (text: String) in
                guard let value = Int64(text.filter(\.isNumber)), value > 0 else { return }
                var updated = condition
                updated.values = [.integer(value), condition.values.count > 1 ? condition.values[1] : .text("days")]
                grid.filter.update(updated)
            }
        )
        let unit = Binding<TimeUnit>(
            get: {
                if condition.values.count > 1, case .text(let raw) = condition.values[1] { return TimeUnit(rawValue: raw) ?? .days }
                return .days
            },
            set: { (unit: TimeUnit) in
                var updated = condition
                updated.values = [condition.values.first ?? .integer(7), .text(unit.rawValue)]
                grid.filter.update(updated)
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FieldBox(height: 32) {
                    TextField("7", text: amount).textFieldStyle(.plain).font(.mono(12.5)).focusEffectDisabled()
                }
                .frame(width: 64)
                SegmentedSwitch(options: [TimeUnit.hours, .days, .weeks, .months].map { (value: $0, label: FilterText.unit($0)) }, selection: unit, height: 26, fill: true)
            }
            HStack(spacing: 6) {
                ForEach([(24, TimeUnit.hours, String(localized: "24 hours")), (7, .days, String(localized: "7 days")), (30, .days, String(localized: "30 days")), (12, .months, String(localized: "a year"))], id: \.2) { preset in
                    Button(preset.2) {
                        var updated = condition
                        updated.values = [.integer(Int64(preset.0)), .text(preset.1.rawValue)]
                        grid.filter.update(updated)
                    }
                    .buttonStyle(.secondary(height: 24))
                    .font(.ui(12))
                }
            }
        }
    }

    /// Values you type or paste, shown as tokens.
    private var typedValues: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldBox(height: 32) {
                TextField(condition.category.isNumeric ? "84211, 84209" : "Type or paste values", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.mono(12.5))
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit(addTyped)
            }
            if !condition.values.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(condition.values, id: \.self) { value in
                        Token(text: FilterText.value(value)) { toggle(value) }
                    }
                }
            }
        }
        .onAppear { focused = true }
    }

    private func addTyped() {
        let separators = CharacterSet(charactersIn: ",\n\t").union(condition.category.isNumeric ? .whitespaces : [])
        let parts = typed.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        var updated = condition
        for part in parts where !updated.values.contains(.text(part)) {
            updated.values.append(.text(part))
        }
        grid.filter.update(updated)
        typed = ""
    }

    private var valueList: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldBox(height: 32) {
                IconView(.search, size: 13).foregroundStyle(Color.tmMuted)
                TextField("Search values", text: $search)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit {
                        if let match = counts.first { toggle(match.value) }
                    }
            }
            ScrollView {
                VStack(spacing: 0) {
                    let maxCount = max(1, counts.map(\.count).max() ?? 1)
                    ForEach(counts, id: \.value) { item in
                        valueRow(item.value, count: item.count, maxCount: maxCount)
                    }
                    let selectedOutside = condition.values.filter { value in !counts.contains { $0.value == value } }
                    ForEach(selectedOutside, id: \.self) { value in
                        valueRow(value, count: nil, maxCount: maxCount)
                    }
                    if counts.isEmpty && !loading {
                        Text(search.isEmpty ? "No values" : "Nothing matches “\(search)”")
                            .foregroundStyle(Color.tmMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 256)
            .fixedSize(horizontal: false, vertical: true)
            if !search.isEmpty && !counts.contains(where: { $0.value.displayText == search }) {
                Button("Use “\(search)”") { toggle(.text(search)) }
                    .buttonStyle(.secondary(height: 26))
                    .font(.ui(12))
            }
        }
        .onAppear { focused = true }
    }

    /// Checkbox, value, a bar for its share of rows, the count.
    private func valueRow(_ value: CellValue, count: Int?, maxCount: Int) -> some View {
        let on = condition.values.contains(value)
        return Button {
            toggle(value)
        } label: {
            HStack(spacing: 10) {
                CheckBox(on: on)
                Text(value.isNull ? String(localized: "empty") : GridStyle.display(value, scale: column?.scale))
                    .font(.mono(12.5))
                    .foregroundStyle(value.isNull ? Color.tmMuted : (on ? Color.tmText : Color.tmText2))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let count {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.tmLine2)
                            RoundedRectangle(cornerRadius: 2).fill(Color.tmMuted.opacity(0.55))
                                .frame(width: max(2, proxy.size.width * CGFloat(count) / CGFloat(maxCount)))
                        }
                    }
                    .frame(width: 64, height: 4)
                    Text(count.grouped).font(.mono(11.5)).foregroundStyle(Color.tmMuted)
                        .frame(width: 48, alignment: .trailing)
                } else {
                    Text("typed").font(.ui(11.5)).foregroundStyle(Color.tmMuted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ value: CellValue) {
        var updated = condition
        if let index = updated.values.firstIndex(of: value) {
            updated.values.remove(at: index)
        } else {
            updated.values.append(value)
        }
        grid.filter.update(updated)
    }

    private func loadFields() {
        switch condition.op {
        case .between:
            first = condition.values.first.map(\.displayText) ?? ""
            second = condition.values.count > 1 ? condition.values[1].displayText : ""
        case .isAnyOf, .isNoneOf, .inLast, .isTrue, .isFalse, .isEmpty, .isNotEmpty:
            break
        default:
            first = condition.values.first.map(\.displayText) ?? ""
        }
        if !usesList { focused = true }
    }

    private func commitFields() {
        var updated = condition
        switch condition.op {
        case .between:
            guard !first.isEmpty, !second.isEmpty else { return }
            updated.values = [.text(first), .text(second)]
        default:
            guard !first.isEmpty else { return }
            updated.values = [.text(first)]
        }
        grid.filter.update(updated)
    }

    private func loadCounts() async {
        guard usesList, column?.isPrimaryKey != true else {
            loading = false
            return
        }
        if !search.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
        guard !Task.isCancelled else { return }
        loading = true
        let result = try? await grid.valueCounts(column: condition.column, excluding: condition.id, search: search.isEmpty ? nil : search)
        guard !Task.isCancelled else { return }
        counts = result ?? []
        if search.isEmpty {
            allDistinct = counts.count >= 20 && counts.allSatisfy { $0.count == 1 }
        }
        loading = false
    }
}
