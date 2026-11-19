import AppKit
import SwiftUI
import AgentableCore

/// One open table: title, filters, the grid and the changes waiting for review.
struct TableScreen: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var grid: GridModel
    @State private var popover: FilterPopover?

    private var tab: TableTab { grid.viewTab }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            switch tab {
            case .structure:
                StructureView(workspace: workspace, grid: grid)
            case .sql:
                SQLScreen(workspace: workspace, grid: grid, document: grid.sql, popover: $popover)
            case .data:
                dataView
            }
        }
        .coordinateSpace(name: FilterPopover.space)
        .overlay(alignment: .topLeading) {
            if let popover, tab != .structure {
                FilterPopoverHost(grid: grid, popover: $popover, current: popover)
            }
        }
        .background(Color.tmWindow)
        .onAppear { if SnapshotHooks.showStructure { grid.viewTab = .structure } }
        .onChange(of: grid.viewTab) { popover = nil }
    }

    @ViewBuilder private var dataView: some View {
            FilterBar(grid: grid, popover: $popover)
            ZStack {
                DataGridView(
                    model: grid,
                    onOpenProposal: { workspace.openReview(selecting: $0) },
                    onFilterColumn: { name in
                        guard let column = grid.columns.first(where: { $0.name == name }) else { return }
                        grid.filterMode = .chips
                        grid.filter.whereText = nil
                        let condition = ValuePicker.starter(for: column)
                        grid.pickerToOpen = condition.id
                        grid.filter.append(condition)
                    },
                    onFilter: { condition in
                        grid.filterMode = .chips
                        grid.filter.whereText = nil
                        grid.filter.append(condition)
                    }
                )
                gridState
            }
            .overlay(alignment: .top) { Hairline() }
            PageBar(grid: grid, popover: $popover)
            if workspace.changeCount > 0 {
                PendingBar(workspace: workspace)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
            }
    }

    /// Title, count and view tabs on one line over a hairline, actions on the right, as drawn.
    private var titleRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if let back = grid.cameFrom {
                    Button {
                        workspace.goBack(from: grid)
                    } label: {
                        HStack(spacing: 4) {
                            IconView(.chevronLeft, size: 14)
                            Text(back.table.name).font(.mono(12))
                            if !back.key.isEmpty { Text(back.key).font(.ui(12.5)) }
                        }
                        .foregroundStyle(Color.tmMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "back.table", defaultValue: "Back to \(back.table.name)"))
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(grid.table.name).font(.ui(20, .semibold)).tracking(-0.4)
                    Text(countLabel).font(.mono(12)).foregroundStyle(Color.tmMuted)
                    if grid.description?.table.kind == .view {
                        Text("view · read-only").font(.ui(12)).foregroundStyle(Color.tmMuted)
                    } else if grid.description != nil && grid.primaryKey.isEmpty {
                        Text("no primary key · read-only").font(.ui(12)).foregroundStyle(Color.tmMuted)
                            .help("Rows can only be edited in tables with a primary key.")
                    }
                }
            }
            .padding(.bottom, 10)
            ViewTabs(options: [(TableTab.data, "Data"), (.structure, "Structure"), (.sql, "SQL")], selection: $grid.viewTab)
            Spacer()
            HStack(spacing: 8) {
                if tab == .data {
                    ColumnsButton(grid: grid, popover: $popover)
                    ExportButton(grid: grid, popover: $popover)
                    Button {
                        grid.addRow()
                    } label: {
                        HStack(spacing: 6) {
                            IconView(.plus, size: 14)
                            Text("Row")
                        }
                    }
                    .buttonStyle(.secondary)
                    .disabled(!grid.canInsert)
                    .help(grid.canInsert ? "Add a row (⌘I)" : "Views don't take new rows")
                } else if tab == .structure {
                    Button {
                        grid.structureSelection = .newColumn(workspace.addColumn(to: grid.table))
                    } label: {
                        HStack(spacing: 6) {
                            IconView(.plus, size: 14)
                            Text("Column")
                        }
                    }
                    .buttonStyle(.secondary)
                    .disabled(!grid.canInsert)
                    .help(grid.canInsert ? "Add a column" : "Views have no columns of their own")
                    Button {
                        let first = grid.description?.columns.first { !$0.primaryKey }?.name ?? grid.description?.columns.first?.name
                        grid.structureSelection = .newIndex(workspace.addIndex(to: grid.table, columns: first.map { [$0] } ?? []))
                    } label: {
                        HStack(spacing: 6) {
                            IconView(.plus, size: 14)
                            Text("Index")
                        }
                    }
                    .buttonStyle(.secondary)
                    .disabled(!grid.canInsert)
                    .help(grid.canInsert ? "Add an index" : "Views have no indexes")
                }
            }
            .fixedSize()
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 18)
        .padding(.top, grid.cameFrom == nil ? 14 : 10)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var countLabel: String {
        switch tab {
        case .data: grid.rowCountLabel
        case .structure: structureLabel
        case .sql: grid.sql.fileName ?? String(localized: "new query")
        }
    }

    /// Counts what the Structure tab shows: waiting new columns and proposed indexes included.
    private var structureLabel: String {
        guard let description = grid.description else { return "" }
        let draft = StructureDraft(description: description, changes: workspace.schemaChanges(for: grid.table), proposals: workspace.pending, dialect: workspace.dialect)
        let columns = draft.columns.filter { $0.mark != .dropped }.count
        let indexes = draft.indexes.filter { $0.mark != .dropped }.count
        let size = description.size.map { " · " + StructureText.size($0) } ?? ""
        let columnsText = columns == 1 ? String(localized: "1 column") : String(localized: "\(columns) columns")
        let indexesText = indexes == 1 ? String(localized: "1 index") : String(localized: "\(indexes) indexes")
        return columnsText + " · " + indexesText + size
    }

    @ViewBuilder private var gridState: some View {
        if let error = grid.error {
            VStack(alignment: .leading, spacing: 8) {
                Text("The query failed").font(.ui(14, .semibold))
                Text(error).font(.mono(12)).foregroundStyle(Color.tmText2).textSelection(.enabled)
                if !grid.filter.isEmpty {
                    Button("Clear filters") { grid.filter = TableFilter() }.buttonStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: 560, alignment: .leading)
            .card()
        } else if grid.loadingFirstPage {
            ProgressView().controlSize(.small)
        } else if grid.rowCount == 0 {
            VStack(spacing: 6) {
                Text(grid.filter.isEmpty ? "No rows yet" : "No rows match").font(.ui(14, .semibold))
                if !grid.filter.isEmpty {
                    Button("Clear filters") { grid.filter = TableFilter() }.buttonStyle(.secondary)
                }
            }
        }
    }
}

/// The "Columns" button; opens the columns panel under it.
struct ColumnsButton: View {
    @Bindable var grid: GridModel
    @Binding var popover: FilterPopover?
    @State private var frame = CGRect.zero

    var body: some View {
        let hidden = grid.columns.filter(\.hidden).count
        Button {
            popover = popover?.kind == .columns ? nil : FilterPopover(kind: .columns, anchor: frame)
        } label: {
            Text(hidden > 0 ? "Columns · \(hidden) hidden" : "Columns")
        }
        .buttonStyle(.secondary)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FilterPopover.space)) } action: { new in
            frame = new
            if SnapshotHooks.openColumns, new.width > 0, !grid.columns.isEmpty {
                SnapshotHooks.openColumns = false
                popover = FilterPopover(kind: .columns, anchor: new)
            }
        }
    }
}

/// The "Export" button; opens the export panel under it.
struct ExportButton: View {
    @Bindable var grid: GridModel
    @Binding var popover: FilterPopover?
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            popover = popover?.kind == .export ? nil : FilterPopover(kind: .export, anchor: frame)
        } label: {
            Text("Export")
        }
        .buttonStyle(.secondary)
        .help("Copy or save these rows as CSV, JSON, SQL or Markdown")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FilterPopover.space)) } action: { new in
            frame = new
            if SnapshotHooks.openExport, new.width > 0 {
                SnapshotHooks.openExport = false
                popover = FilterPopover(kind: .export, anchor: new)
            }
        }
    }
}

/// SQL shown like a slip of paper: one tidy block with a copy button, never the main screen.
struct SQLSlip: View {
    let title: String.LocalizationValue
    let sql: String
    var note: String? = nil
    var onClose: (() -> Void)? = nil
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionLabel(text: title)
                if let note { Text(note).font(.ui(12)).foregroundStyle(Color.tmMuted) }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                    copied = true
                }
                .buttonStyle(.secondary(height: 26))
                if let onClose {
                    Button(action: onClose) { IconView(.close, size: 13) }
                        .buttonStyle(QuietButtonStyle(size: 26))
                        .accessibilityLabel("Close")
                }
            }
            Text(SQLFormatter.pretty(sql))
                .font(.mono(12))
                .foregroundStyle(Color.tmText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.tmSide, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.tmLine))
    }
}

/// Puts the main clauses of a generated statement on their own lines.
enum SQLFormatter {
    /// Structure statements and comments stay on one line each.
    static func pretty(_ sql: String) -> String {
        sql.components(separatedBy: "\n").map { line in
            let start = line.trimmingCharacters(in: .whitespaces).uppercased()
            return ["ALTER ", "CREATE ", "DROP ", "--"].contains(where: start.hasPrefix) ? line : clauses(line)
        }
        .joined(separator: "\n")
    }

    private static func clauses(_ sql: String) -> String {
        var text = sql
        for keyword in [" FROM ", " WHERE ", " ORDER BY ", " LIMIT ", " SET ", " GROUP BY "] {
            text = text.replacingOccurrences(of: keyword, with: "\n" + keyword.trimmingCharacters(in: .whitespaces) + " ")
        }
        text = text.replacingOccurrences(of: " AND ", with: "\n  AND ")
        return text
    }
}
