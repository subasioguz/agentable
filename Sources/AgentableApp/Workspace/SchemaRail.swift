import SwiftUI
import AgentableCore

/// Tables with row counts; open one to see its columns and types.
struct SchemaRail: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldBox(height: 30) {
                IconView(.filter, size: 13).foregroundStyle(Color.tmMuted)
                TextField("Filter tables, columns", text: $workspace.railFilter)
                    .textFieldStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(schemas, id: \.self) { schema in
                        let tables = visibleTables(in: schema)
                        if !tables.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    SectionLabel(verbatim: schema)
                                    Spacer()
                                    (tables.count == 1 ? Text("1 table") : Text("\(tables.count) tables"))
                                        .font(.ui(11, .medium)).foregroundStyle(Color.tmMuted)
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 6)
                                ForEach(tables, id: \.self) { table in
                                    SchemaTableRow(workspace: workspace, table: table)
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.tmSide)
    }

    private var schemas: [String] {
        var seen: [String] = []
        for table in workspace.tables {
            let name = table.schema ?? "main"
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private func visibleTables(in schema: String) -> [TableSummary] {
        let needle = workspace.railFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let rules = workspace.profile.rules
        let matching = workspace.tables.filter { table in
            guard (table.schema ?? "main") == schema else { return false }
            guard !needle.isEmpty else { return true }
            if table.name.lowercased().contains(needle) { return true }
            let columns = workspace.descriptions[TableRef(table)]?.columns ?? []
            return columns.contains { $0.name.lowercased().contains(needle) }
        }
        // Tables hidden from agents go last, as in the design.
        return matching.filter { !AgentPolicy.isHidden(table: $0.name, rules: rules) }
            + matching.filter { AgentPolicy.isHidden(table: $0.name, rules: rules) }
    }
}

private struct SchemaTableRow: View {
    @Bindable var workspace: WorkspaceModel
    let table: TableSummary
    @State private var hovering = false

    private var ref: TableRef { TableRef(table) }

    var body: some View {
        let selected = workspace.currentTable == ref
        let expanded = workspace.expanded.contains(ref) || (!workspace.railFilter.isEmpty && matchesColumn)
        let hidden = AgentPolicy.isHidden(table: table.name, rules: workspace.profile.rules)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if hidden {
                    IconView(.hidden, size: 14).foregroundStyle(Color.tmMuted).frame(width: 14, height: 20)
                } else {
                Button {
                    toggle()
                } label: {
                    IconView(expanded ? .chevronDown : .chevronRight, size: 13, weight: 1.8)
                        .foregroundStyle(Color.tmMuted)
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide columns" : "Show columns")
                }
                Text(table.name)
                    .font(.ui(13, selected ? .semibold : .regular))
                    .foregroundStyle(hidden ? Color.tmMuted : (selected ? Color.tmText : Color.tmText2))
                    .lineLimit(1)
                if table.kind == .view {
                    Text("view").font(.mono(10.5)).foregroundStyle(Color.tmMuted)
                }
                Spacer(minLength: 4)
                trailing(hidden: hidden)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(selected ? Color.tmWindow : (hovering ? Color.tmChip : .clear), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.tmLine) }
            }
            .contentShape(Rectangle())
            .onTapGesture { workspace.open(ref) }
            .onHover { hovering = $0 }
            .help(hidden ? String(localized: "Hidden from agents") : table.name)

            if expanded {
                if let description = workspace.descriptions[ref] {
                    ForEach(description.columns, id: \.name) { column in
                        ColumnRow(column: column, foreign: description.foreignKeys.first { $0.column == column.name })
                    }
                } else {
                    ProgressView().controlSize(.mini).padding(.leading, 30).frame(height: 24)
                }
            }
        }
        .task(id: expanded) {
            if expanded { _ = await workspace.describe(ref) }
        }
    }

    private var matchesColumn: Bool {
        let needle = workspace.railFilter.lowercased()
        return workspace.descriptions[ref]?.columns.contains { $0.name.lowercased().contains(needle) } ?? false
    }

    @ViewBuilder private func trailing(hidden: Bool) -> some View {
        if hidden {
            Text("hidden").font(.mono(11.5)).foregroundStyle(Color.tmMuted)
        } else if recentlyTouchedByAgent {
            HStack(spacing: 5) {
                Dot(color: .tmAgent, size: 6)
                Text("agent")
            }
            .font(.mono(11.5))
            .foregroundStyle(Color.tmAgentText)
        } else if let count = workspace.estimates[ref] {
            Text(count.compact).font(.mono(11.5)).foregroundStyle(Color.tmMuted)
        }
    }

    private var recentlyTouchedByAgent: Bool {
        let name = table.name.lowercased()
        let cutoff = Date.now.addingTimeInterval(-ActivityFeed.presenceWindow)
        return workspace.events.suffix(40).contains { item in
            item.event.client != "you" && item.event.at > cutoff && SQLText.mentions(item.event.sql.lowercased(), name)
        }
    }

    private func toggle() {
        if workspace.expanded.contains(ref) {
            workspace.expanded.remove(ref)
        } else {
            workspace.expanded.insert(ref)
        }
    }
}

private struct ColumnRow: View {
    let column: ColumnInfo
    let foreign: ForeignKeyInfo?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if column.primaryKey {
                    IconView(.key, size: 14).foregroundStyle(Color.tmWarn)
                } else if foreign != nil {
                    IconView(.reference, size: 14).foregroundStyle(Color.tmYou)
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .frame(width: 14)
            Text(column.name).font(.mono(12)).foregroundStyle(Color.tmText2).lineLimit(1)
            Spacer(minLength: 4)
            Text(GridModel.shortType(column.type)).font(.mono(11.5)).foregroundStyle(Color.tmMuted).lineLimit(1)
        }
        .padding(.leading, 26)
        .padding(.trailing, 6)
        .frame(height: 24)
        .help(foreign.map { "\(column.name) → \($0.referencedTable)" } ?? "\(column.name) · \(column.type)")
    }
}
