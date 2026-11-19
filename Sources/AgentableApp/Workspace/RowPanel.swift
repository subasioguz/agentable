import AppKit
import SwiftUI
import AgentableCore

/// The selected row, one column per line: long text wraps, JSON is indented, a foreign key links
/// to the row it points to, and tables pointing at this row are listed with their counts.
/// Space in the grid opens and closes it.
struct RowPanel: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var grid: GridModel
    @State private var references: [IncomingReference] = []
    @State private var counts: [IncomingReference: Int] = [:]
    @State private var labels: [String: String] = [:]
    @State private var editing: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    private enum Selected {
        case row([CellValue])
        case new(RowChange)
    }

    private var selected: Selected? {
        guard let index = grid.selection.first, index < grid.displayCount else { return nil }
        switch grid.displayRow(index) {
        case .data(let row): return grid.loadedRow(row).map { .row($0) }
        case .new(let id): return grid.insert(id).map { .new($0) }
        case .note: return nil
        }
    }

    /// Changes when another row is selected, so references and labels reload.
    private var identity: String {
        switch selected {
        case .row(let row)?: "\(grid.table.path)|\(grid.keyText(of: row))"
        case .new(let change)?: "new|\(change.id)"
        case nil: "none"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline(color: .tmLine2)
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(grid.columns) { column in
                            field(column, in: selected)
                        }
                        if case .row(let row) = selected, !references.isEmpty {
                            referencedBy(row)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
            } else {
                Text("No row selected")
                    .font(.ui(13))
                    .foregroundStyle(Color.tmMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.tmPanel)
        .task(id: identity) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Row").font(.ui(14, .semibold)).foregroundStyle(Color.tmText)
            HStack(spacing: 5) {
                Text(grid.table.name).font(.mono(11.5))
                switch selected {
                case .row(let row)?: Text(grid.keyText(of: row)).font(.ui(12))
                case .new?: Text("new row").font(.ui(12))
                case nil: EmptyView()
                }
            }
            .foregroundStyle(Color.tmMuted)
            .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                workspace.showRow = false
            } label: {
                IconView(.close, size: 13)
            }
            .buttonStyle(QuietButtonStyle(size: 28))
            .help("Close (Space)")
            .accessibilityLabel("Close")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 48)
    }

    // MARK: Fields

    private func field(_ column: GridColumn, in selected: Selected) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if column.isPrimaryKey { IconView(.key, size: 11).foregroundStyle(Color.tmWarn) }
                    Text(column.name).font(.mono(12, .medium)).foregroundStyle(Color.tmText2).lineLimit(1)
                }
                Text(column.type).font(.mono(11)).foregroundStyle(Color.tmMuted).lineLimit(1)
            }
            .frame(width: 108, alignment: .leading)
            .help(Text(verbatim: "\(column.name) · \(column.type)"))
            Group {
                if editing == column.name {
                    editor(column, in: selected)
                } else {
                    value(column, in: selected)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Hairline(color: .tmLine2) }
    }

    @ViewBuilder private func value(_ column: GridColumn, in selected: Selected) -> some View {
        switch selected {
        case .row(let row):
            let current = grid.value(row: row, column: column.name) ?? .null
            if case .edited(let was, let now) = grid.mark(row: row, column: column.name) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(GridStyle.display(was, scale: column.scale)).strikethrough().foregroundStyle(Color.tmMuted)
                    Text(now.isNull ? "NULL" : now.displayText).foregroundStyle(now.isNull ? Color.tmMuted : Color.tmText)
                }
                .font(.mono(12.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.tmYouTint, in: RoundedRectangle(cornerRadius: 5))
                .onTapGesture(count: 2) { startEditing(column, current: now) }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    valueText(current, column: column)
                    if let key = column.foreignKey, !current.isNull {
                        link(key, column: column, row: row)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if grid.isEditable { startEditing(column, current: current) } }
            }
        case .new(let change):
            let given: CellValue? = if case .insert(let values) = change.kind { values.first { $0.column == column.name }?.value } else { nil }
            Group {
                if let given {
                    valueText(given, column: column)
                } else {
                    Text(grid.placeholder(for: column)).font(.mono(12.5)).foregroundStyle(Color.tmMuted)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { startEditing(column, current: given ?? .null) }
        }
    }

    @ViewBuilder private func valueText(_ value: CellValue, column: GridColumn) -> some View {
        if value.isNull {
            Text("NULL").font(.mono(12.5)).foregroundStyle(Color.tmMuted)
        } else if column.category == .json, case .text(let raw) = value, let pretty = JSONPretty.attributed(raw) {
            Text(pretty)
                .font(.mono(11.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine))
        } else if column.category == .text, column.name.lowercased().contains("status") || column.name.lowercased() == "state",
                  case .text(let word) = value, let tint = GridStyle.statusColor(word) {
            HStack(spacing: 7) {
                Dot(color: Color(nsColor: tint), size: 7)
                Text(word).font(.mono(12.5)).foregroundStyle(Color(nsColor: tint))
            }
        } else {
            Text(column.scale.flatMap { _ in GridStyle.display(value, scale: column.scale) } ?? value.displayText)
                .font(.mono(12.5))
                .foregroundStyle(Color.tmText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "↗ customers  Priya Raman": opens the row the key points to.
    private func link(_ key: ForeignKeyInfo, column: GridColumn, row: [CellValue]) -> some View {
        Button {
            grid.follow(column: column.name, in: row)
        } label: {
            HStack(spacing: 6) {
                IconView(.reference, size: 12)
                Text(key.referencedTable).font(.mono(12))
                if let label = labels[column.name] {
                    Text(label).font(.ui(12.5)).foregroundStyle(Color.tmMuted).lineLimit(1)
                }
            }
            .foregroundStyle(Color.tmYou)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "open.table", defaultValue: "Open \(key.referencedTable)"))
    }

    // MARK: Editing

    private func editor(_ column: GridColumn, in selected: Selected) -> some View {
        FieldBox(height: 28) {
            TextField(column.nullable ? "NULL" : "", text: $text)
                .textFieldStyle(.plain)
                .font(.mono(12.5))
                .focused($focused)
                .onSubmit { commit(column, in: selected) }
                .onExitCommand { editing = nil }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmYou, lineWidth: 1.5))
    }

    private func startEditing(_ column: GridColumn, current: CellValue) {
        text = current.isNull ? "" : current.displayText
        editing = column.name
        focused = true
    }

    private func commit(_ column: GridColumn, in selected: Selected) {
        editing = nil
        switch selected {
        case .row(let row):
            let original = grid.value(row: row, column: column.name) ?? .null
            let shown: CellValue = if case .edited(_, let now) = grid.mark(row: row, column: column.name) { now } else { original }
            let same = (shown.isNull && text.isEmpty) || (!shown.isNull && shown.displayText == text)
            guard !same else { return }
            let unchanged = (original.isNull && text.isEmpty) || (!original.isNull && original.displayText == text)
            grid.stageEdit(row: row, column: column.name, to: unchanged ? original : grid.parse(text, for: column))
        case .new(let change):
            grid.setInsertValue(change.id, column: column.name, to: text.isEmpty ? nil : grid.parse(text, for: column))
        }
    }

    // MARK: Referenced by

    private func referencedBy(_ row: [CellValue]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Referenced by")
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)
            ForEach(references, id: \.self) { reference in
                let count = counts[reference]
                Button {
                    follow(reference, row: row)
                } label: {
                    HStack(spacing: 10) {
                        Text(reference.table).font(.mono(12)).foregroundStyle(count == 0 ? Color.tmMuted : Color.tmText).lineLimit(1)
                        Text(reference.column).font(.mono(11.5)).foregroundStyle(Color.tmMuted).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(count.map(\.grouped) ?? "…").font(.mono(11.5)).foregroundStyle(Color.tmMuted)
                        IconView(.chevronRight, size: 14).foregroundStyle(Color.tmMuted).opacity(count == 0 ? 0 : 1)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                .disabled(count == 0)
                .help("Open \(reference.table) rows whose \(reference.column) points here")
            }
            .padding(.horizontal, 8)
        }
    }

    /// The value in this row that a reference points at: its named column, or the primary key.
    private func target(_ reference: IncomingReference, row: [CellValue]) -> CellValue? {
        let column = reference.referencedColumn ?? grid.primaryKey.first
        return column.flatMap { grid.value(row: row, column: $0) }
    }

    private func follow(_ reference: IncomingReference, row: [CellValue]) {
        guard let value = target(reference, row: row), !value.isNull else { return }
        workspace.follow(to: TableRef(schema: reference.schema, name: reference.table), column: reference.column,
                         value: value, from: grid.table, key: grid.keyText(of: row))
    }

    private func load() async {
        guard case .row(let row)? = selected else { return }
        var found: [String: String] = [:]
        for column in grid.columns {
            guard let key = column.foreignKey, let value = grid.value(row: row, column: column.name), !value.isNull,
                  let target = await workspace.referencedColumn(key) else { continue }
            if let label = await workspace.rowLabel(workspace.referencedTable(key), column: target, value: value) {
                found[column.name] = label
            }
            if Task.isCancelled { return }
        }
        labels = found
        references = await workspace.references(to: grid.table)
        counts = [:]
        for reference in references {
            guard let value = target(reference, row: row), !value.isNull else { counts[reference] = 0; continue }
            if let count = await workspace.countReferencing(reference, value: value) { counts[reference] = count }
            if Task.isCancelled { return }
        }
    }
}

/// Re-indents JSON text without reordering keys or reformatting numbers, keys in a darker gray and
/// punctuation and nulls muted.
enum JSONPretty {
    static func attributed(_ raw: String) -> AttributedString? {
        guard raw.count <= 20_000, let data = raw.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        var out = AttributedString()
        var depth = 0
        let chars = Array(raw)
        var index = 0

        func add(_ text: String, _ color: Color) {
            var part = AttributedString(text)
            part.foregroundColor = color
            out += part
        }
        func newline() { add("\n" + String(repeating: "  ", count: depth), .tmMuted) }
        func nextSignificant(after position: Int) -> Character? {
            var at = position
            while at < chars.count, chars[at].isWhitespace { at += 1 }
            return at < chars.count ? chars[at] : nil
        }

        while index < chars.count {
            let char = chars[index]
            switch char {
            case "\"":
                var end = index + 1
                while end < chars.count, chars[end] != "\"" { end += chars[end] == "\\" ? 2 : 1 }
                let string = String(chars[index...min(end, chars.count - 1)])
                add(string, nextSignificant(after: end + 1) == ":" ? .tmText2 : .tmText)
                index = end + 1
                continue
            case "{", "[":
                let close: Character = char == "{" ? "}" : "]"
                if nextSignificant(after: index + 1) == close {
                    add(String(char) + String(close), .tmMuted)
                    var at = index + 1
                    while chars[at] != close { at += 1 }
                    index = at + 1
                    continue
                }
                add(String(char), .tmMuted)
                depth += 1
                newline()
            case "}", "]":
                depth -= 1
                newline()
                add(String(char), .tmMuted)
            case ",":
                add(",", .tmMuted)
                newline()
            case ":":
                add(": ", .tmMuted)
            case _ where char.isWhitespace:
                break
            default:
                var end = index
                while end < chars.count, !",}]: \n\t\r".contains(chars[end]) { end += 1 }
                let word = String(chars[index..<end])
                add(word, word == "null" ? .tmMuted : .tmText)
                index = end
                continue
            }
            index += 1
        }
        return out
    }
}
