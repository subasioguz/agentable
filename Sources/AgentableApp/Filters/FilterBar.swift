import SwiftUI
import AgentableCore

/// Which floating filter panel is open and where it hangs from.
struct FilterPopover: Equatable {
    enum Kind: Equatable {
        case value(UUID)
        case addColumn
        case columns
        case export
        case saveQuery
        case ask
        /// Opens upward, from the page bar under the table.
        case pages
    }

    var kind: Kind
    /// The control it opened from, in the table screen's coordinate space.
    var anchor: CGRect

    static let space = "tableScreen"
}

/// Chips for daily use, condition rows when it gets complicated, raw WHERE for SQL people.
struct FilterBar: View {
    @Bindable var grid: GridModel
    @Binding var popover: FilterPopover?

    var body: some View {
        VStack(spacing: 0) {
            switch grid.filterMode {
            case .chips:
                chipsRow
            case .advanced:
                AdvancedFilterPanel(grid: grid)
            case .sql:
                WhereEditor(grid: grid)
            }
        }
    }

    private var modeSwitch: some View {
        SegmentedSwitch(
            options: FilterText.modes,
            selection: Binding(get: { grid.filterMode }, set: { switchMode(to: $0) })
        )
        .fixedSize()
    }

    private func switchMode(to mode: FilterMode) {
        popover = nil
        if mode == .chips, grid.filter.usesWhereText {
            // Typed WHERE text cannot become chips; going back starts from the last condition rows.
            grid.filter.whereText = nil
        }
        grid.filterMode = mode
    }

    private var chipsRow: some View {
        HStack(alignment: .top, spacing: 8) {
            SearchBox(text: $grid.search)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                chips
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            modeSwitch
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var chips: some View {
        Group {
            if grid.filter.usesWhereText {
                CustomWhereChip(text: grid.filter.whereText ?? "") { grid.filterMode = .sql } onRemove: { grid.filter.whereText = nil }
            } else if !grid.filter.isFlat {
                CustomWhereChip(text: FilterText.sentence(grid.filter) ?? "", label: "Advanced") { grid.filterMode = .advanced } onRemove: { grid.filter = TableFilter() }
            } else {
                ForEach(grid.filter.conditions) { condition in
                    FilterChip(condition: condition, active: popover?.kind == .value(condition.id), autoOpen: grid.pickerToOpen == condition.id) { anchor in
                        if grid.pickerToOpen == condition.id { grid.pickerToOpen = nil }
                        popover = FilterPopover(kind: .value(condition.id), anchor: anchor)
                    } onRemove: {
                        if popover?.kind == .value(condition.id) { popover = nil }
                        grid.filter.remove(condition.id)
                    }
                }
            }
            AddFilterButton(compact: !grid.filter.isEmpty) { anchor in
                popover = FilterPopover(kind: .addColumn, anchor: anchor)
            }
            .disabled(!grid.filter.isFlat)
        }
    }
}

/// One condition as a segmented chip: column, operator, value, remove.
struct FilterChip: View {
    let condition: FilterCondition
    let active: Bool
    var autoOpen = false
    let onOpen: (CGRect) -> Void
    let onRemove: () -> Void
    @State private var frame = CGRect.zero

    var body: some View {
        HStack(spacing: 0) {
            segment {
                Text(condition.column).font(.mono(12, .medium)).foregroundStyle(Color.tmText)
            }
            divider
            segment {
                Text(FilterText.chip(condition.op, condition.category)).font(.ui(12.5)).foregroundStyle(Color.tmMuted)
            }
            if condition.op.arity != 0 || condition.op == .isTrue || condition.op == .isFalse {
                divider
                segment {
                    Text(condition.isComplete ? FilterText.valueLabel(condition) : "…")
                        .font(.ui(12.5, .semibold))
                        .foregroundStyle(condition.isComplete ? Color.tmText : Color.tmMuted)
                        .lineLimit(1)
                }
            }
            divider
            Button(action: onRemove) {
                IconView(.close, size: 12, weight: 2).foregroundStyle(Color.tmMuted)
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove filter on \(condition.column)")
        }
        .frame(height: 28)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Color.tmYou : Color.tmLine))
        .background(RoundedRectangle(cornerRadius: 8).stroke(active ? Color.tmYouTint : .clear, lineWidth: 6))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FilterPopover.space)) } action: { new in
            frame = new
            if SnapshotHooks.openValuePickerFor == condition.column || autoOpen {
                SnapshotHooks.openValuePickerFor = nil
                onOpen(new)
            }
        }
    }

    private var divider: some View { Rectangle().fill(Color.tmLine2).frame(width: 1) }

    private func segment<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Button {
            onOpen(frame)
        } label: {
            content()
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A chip standing in for filters chips cannot show (typed WHERE text, or grouped conditions).
private struct CustomWhereChip: View {
    let text: String
    var label: LocalizedStringKey = "WHERE"
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Text(label).font(.ui(11, .semibold)).foregroundStyle(Color.tmYou)
                    Text(text).font(.mono(12)).foregroundStyle(Color.tmText).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: 460, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Color.tmLine2).frame(width: 1)
            Button(action: onRemove) {
                IconView(.close, size: 12, weight: 2).foregroundStyle(Color.tmMuted)
                    .frame(width: 26, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear filter")
        }
        .frame(height: 28)
        .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine))
    }
}

private struct AddFilterButton: View {
    let compact: Bool
    let onOpen: (CGRect) -> Void
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            onOpen(frame)
        } label: {
            HStack(spacing: 6) {
                IconView(.plus, size: 13)
                Text("Filter")
            }
            .font(.ui(13))
            .foregroundStyle(Color.tmText2)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FilterPopover.space)) } action: { frame = $0 }
    }
}

/// Draws the open filter panel above the grid and closes it on a click outside.
struct FilterPopoverHost: View {
    @Bindable var grid: GridModel
    @Binding var popover: FilterPopover?
    let current: FilterPopover

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .onTapGesture { close() }
            Group {
                switch current.kind {
                case .value(let id):
                    if let condition = grid.filter.conditions.first(where: { $0.id == id }) {
                        ValuePicker(grid: grid, condition: condition) { close() }
                    }
                case .columns:
                    ColumnsPanel(grid: grid)
                case .export:
                    ExportPanel(grid: grid)
                case .saveQuery:
                    SaveQueryPanel(document: grid.sql) { popover = nil }
                case .ask:
                    AskPanel(document: grid.sql, connection: grid.workspace?.profile.name ?? "") { popover = nil }
                case .pages:
                    PagesPanel(grid: grid) { popover = nil }
                case .addColumn:
                    ColumnPicker(grid: grid) { column in
                        let condition = ValuePicker.starter(for: column)
                        grid.filter.append(condition)
                        popover = FilterPopover(kind: .value(condition.id), anchor: current.anchor)
                    }
                }
            }
            .card()
            .alignmentGuide(.leading) { panel in
                // Panels opened from the right edge hang left from their button.
                [.columns, .export, .saveQuery, .ask, .pages].contains(current.kind) ? -(current.anchor.maxX - panel.width) : -max(8, current.anchor.minX)
            }
            .alignmentGuide(.top) { panel in
                current.kind == .pages ? -(current.anchor.minY - panel.height - 6) : -(current.anchor.maxY + 6)
            }
        }
        .onExitCommand { close() }
    }

    /// Closing drops a condition that never got its values.
    private func close() {
        if case .value(let id) = current.kind, let condition = grid.filter.conditions.first(where: { $0.id == id }), !condition.isComplete {
            grid.filter.remove(id)
        }
        popover = nil
    }
}

/// Pick the column a new filter is on.
struct ColumnPicker: View {
    @Bindable var grid: GridModel
    let onPick: (GridColumn) -> Void
    @State private var search = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldBox(height: 32) {
                IconView(.search, size: 13).foregroundStyle(Color.tmMuted)
                TextField("Filter by column", text: $search)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = matches.first { onPick(first) } }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matches) { column in
                        Button {
                            onPick(column)
                        } label: {
                            HStack(spacing: 10) {
                                Text(column.name).font(.mono(12.5)).foregroundStyle(Color.tmText)
                                Spacer()
                                Text(column.type).font(.mono(11.5)).foregroundStyle(Color.tmMuted)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowStyle())
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 280)
        .onAppear { focused = true }
    }

    private var matches: [GridColumn] {
        let needle = search.lowercased()
        return grid.columns.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
    }
}

/// A list row that tints on hover.
struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Color.tmChip : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}

/// Searches every column without making a filter. ⌘F puts the cursor in it.
private struct SearchBox: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        FieldBox(height: 30, focused: focused) {
            IconView(.search, size: 14).foregroundStyle(Color.tmMuted)
            TextField("Search rows", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: { IconView(.close, size: 12).foregroundStyle(Color.tmMuted) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .frame(width: 210)
        .background {
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }
}

/// Show, hide and find columns.
struct ColumnsPanel: View {
    @Bindable var grid: GridModel
    @State private var search = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldBox(height: 32) {
                IconView(.search, size: 14).foregroundStyle(Color.tmMuted)
                TextField("Find a column", text: $search).textFieldStyle(.plain).focused($focused)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(grid.columns.indices.filter { search.isEmpty || grid.columns[$0].name.lowercased().contains(search.lowercased()) }, id: \.self) { index in
                        let column = grid.columns[index]
                        Button {
                            guard column.hidden || grid.visibleColumns.count > 1 else { return }
                            grid.columns[index].hidden.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                CheckBox(on: !column.hidden)
                                Text(column.name).font(.mono(12.5)).foregroundStyle(column.hidden ? Color.tmMuted : Color.tmText)
                                Spacer()
                                Text(column.type).font(.mono(11.5)).foregroundStyle(Color.tmMuted)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowStyle())
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                let hidden = grid.columns.contains(where: \.hidden)
                let custom = grid.hasCustomLayout
                Text(shownNote(reorderHint: !(hidden || custom)))
                    .font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
                Spacer(minLength: 4)
                if hidden {
                    Button("Show all") { for index in grid.columns.indices { grid.columns[index].hidden = false } }
                        .buttonStyle(.text(height: 26, size: 12))
                }
                if custom {
                    Button("Reset layout") { grid.resetLayout() }
                        .buttonStyle(.text(height: 26, size: 12))
                        .help("Every column back in the table's order and width, sorted by the default order")
                }
            }
            .padding(.top, 6)
            .overlay(alignment: .top) { Hairline(color: .tmLine2) }
        }
        .padding(10)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func shownNote(reorderHint: Bool) -> LocalizedStringKey {
        let shown = grid.visibleColumns.count
        let total = grid.columns.count
        return reorderHint ? "\(shown) of \(total) shown · drag headers to reorder" : "\(shown) of \(total) shown"
    }
}
