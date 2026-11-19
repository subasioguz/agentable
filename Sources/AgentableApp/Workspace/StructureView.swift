import SwiftUI
import AgentableCore

/// The table's structure with your waiting changes laid over it, and agents' proposed indexes.
@MainActor
struct StructureDraft {
    enum Mark: Equatable { case none, new, edited, dropped, proposed }

    struct Column: Identifiable {
        let id: StructureItem
        /// As it will be: the new values of an edited column.
        let shape: ColumnShape
        /// As it was loaded; `nil` for a new column.
        let loaded: ColumnInfo?
        let mark: Mark
        let staged: RowChange?

        var oldShape: ColumnShape? { loaded.map(ColumnShape.init) }
    }

    struct Index: Identifiable {
        let id: StructureItem
        let shape: IndexShape
        let loaded: IndexInfo?
        let mark: Mark
        let staged: RowChange?
        var proposal: Proposal? = nil
        var method: String? = nil
        var concurrently = false
    }

    var columns: [Column] = []
    var indexes: [Index] = []

    init(description: TableDescription, changes: [RowChange], proposals: [Proposal], dialect: SQLDialect) {
        for info in description.columns {
            let change = changes.first { WorkspaceModel.changes(column: info.name, $0) }
            switch change?.schemaChange {
            case .alterColumn(_, let new)?:
                columns.append(Column(id: .column(info.name), shape: new, loaded: info, mark: .edited, staged: change))
            case .dropColumn?:
                columns.append(Column(id: .column(info.name), shape: ColumnShape(info), loaded: info, mark: .dropped, staged: change))
            default:
                columns.append(Column(id: .column(info.name), shape: ColumnShape(info), loaded: info, mark: .none, staged: nil))
            }
        }
        for info in description.indexes {
            let drop = changes.first { $0.schemaChange == .dropIndex(IndexShape(info)) }
            indexes.append(Index(id: .index(info.name), shape: IndexShape(info), loaded: info, mark: drop == nil ? .none : .dropped, staged: drop))
        }
        for change in changes {
            switch change.schemaChange {
            case .addColumn(let shape)?:
                columns.append(Column(id: .newColumn(change.id), shape: shape, loaded: nil, mark: .new, staged: change))
            case .addIndex(let shape)?:
                indexes.append(Index(id: .newIndex(change.id), shape: shape, loaded: nil, mark: .new, staged: change))
            default:
                break
            }
        }
        for proposal in proposals {
            guard let proposed = ProposedIndex.parse(proposal.sql, dialect: dialect),
                  proposed.table.name.caseInsensitiveCompare(description.table.name) == .orderedSame,
                  proposed.table.schema == nil || proposed.table.schema == description.table.schema else { continue }
            indexes.append(Index(
                id: .index("proposal:" + proposal.id), shape: proposed.index, loaded: nil, mark: .proposed, staged: nil,
                proposal: proposal, method: proposed.method, concurrently: proposed.concurrently
            ))
        }
    }

    func column(_ item: StructureItem) -> Column? { columns.first { $0.id == item } }
    func index(_ item: StructureItem) -> Index? { indexes.first { $0.id == item } }
}

/// Words for structure values, shared by the table and the side panel.
@MainActor
enum StructureText {
    /// "identity", "serial", `'pending'` for `'pending'::text`.
    static func defaultLabel(_ value: String?, identity: Bool = false) -> String {
        if identity { return "identity" }
        guard let value else { return "" }
        if value.lowercased().hasPrefix("nextval(") { return "serial" }
        if let match = value.firstMatch(of: #/^('(?:[^']|'')*')::[a-z ]+(\[\])?$/#) { return String(match.1) }
        if let match = value.firstMatch(of: #/^\((-?[0-9.]+)\)::[a-z ]+$/#) { return String(match.1) }
        return value
    }

    static func type(_ value: String) -> String {
        GridModel.shortType(value)
    }

    /// "27 MB"
    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.locale))
    }

    /// "8.1M scans", "910k scans", "1 scan" (Turkish: "8,1 Mn tarama")
    static func scans(_ count: Int64) -> String {
        let number = L10n.compact(Int(count)) {
            switch count {
            case 1_000_000...: trimmed(Double(count) / 1_000_000) + "M"
            case 10_000...: "\(count / 1_000)k"
            case 1_000...: trimmed(Double(count) / 1_000) + "k"
            default: "\(count)"
            }
        }
        return count == 1 ? String(localized: "1 scan") : String(localized: "\(number) scans")
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// "btree · unique", "unique"; a proposed PostgreSQL index without USING is a btree. The
    /// method and CONCURRENTLY are SQL words and stay as written.
    static func kind(_ index: StructureDraft.Index, dialect: SQLDialect) -> String {
        let method = index.loaded?.method ?? index.method ?? (index.loaded == nil && dialect == .postgres ? "btree" : nil)
        return [method, index.shape.unique ? String(localized: "unique") : nil, index.concurrently ? "concurrently" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "yes", "no"
    static func yesNo(_ value: Bool) -> String {
        value ? String(localized: "yes") : String(localized: "no")
    }

    /// "check · 6 values", "check · ≥ 0", "check". Core's `shortLabel` is English, so the value
    /// count is worded here.
    static func check(_ check: CheckInfo) -> String {
        if let values = check.allowedValues {
            return values.count == 1 ? String(localized: "check · 1 value") : String(localized: "check · \(values.count) values")
        }
        return check.shortLabel.map { "check · " + $0 } ?? "check"
    }

    /// "proposed by claude-code"
    static func proposedBy(_ proposal: Proposal?) -> String {
        proposal.map { String(localized: "proposed by \($0.client)") } ?? String(localized: "proposed by an agent")
    }
}

/// The Structure tab: columns and indexes, as drawn on the canvas. Click one to change it in the
/// side panel; changes wait with your other edits until you save.
struct StructureView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var grid: GridModel

    var body: some View {
        VStack(spacing: 0) {
            if let description = grid.description {
                let draft = StructureDraft(
                    description: description, changes: workspace.schemaChanges(for: grid.table),
                    proposals: workspace.pending, dialect: workspace.dialect
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Columns")
                        columnsTable(draft, description: description)
                        SectionLabel(text: "Indexes").padding(.top, 8)
                        indexesTable(draft)
                        ForEach(draft.indexes.compactMap(\.proposal), id: \.id) { proposal in
                            if let reason = proposal.reason {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(proposal.client).font(.ui(12.5, .semibold)).foregroundStyle(Color.tmAgentText)
                                    Text(reason).font(.ui(12.5)).foregroundStyle(Color.tmText2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onExitCommand { grid.structureSelection = nil }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if workspace.changeCount > 0 {
                PendingBar(workspace: workspace, structure: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
            }
        }
    }

    // MARK: Columns

    private func columnsTable(_ draft: StructureDraft, description: TableDescription) -> some View {
        BorderedTable(headers: [("column", 180), ("type", 150), ("null", 60), ("default", 170), ("keys and checks", nil)]) {
            ForEach(draft.columns) { column in
                columnRow(column, description: description, last: column.id == draft.columns.last?.id)
            }
        }
    }

    private func columnRow(_ column: StructureDraft.Column, description: TableDescription, last: Bool) -> some View {
        let selected = grid.structureSelection == column.id
        let old = column.oldShape
        let edited = column.mark == .edited
        let struck = column.mark == .dropped
        return HStack(spacing: 0) {
            cell(column.shape.name, was: edited && old?.name != column.shape.name ? old?.name : nil,
                 width: 180, color: .tmText, weight: selected ? .semibold : .regular, struck: struck)
            cell(StructureText.type(column.shape.type), was: edited && old?.type != column.shape.type ? old.map { StructureText.type($0.type) } : nil,
                 width: 150, color: .tmMuted, struck: struck)
            cell(StructureText.yesNo(column.shape.nullable), was: edited && old?.nullable != column.shape.nullable ? StructureText.yesNo(old!.nullable) : nil,
                 width: 60, color: .tmMuted, struck: struck)
            cell(StructureText.defaultLabel(column.shape.defaultValue, identity: column.loaded?.identity ?? false),
                 was: edited && old?.defaultValue != column.shape.defaultValue ? StructureText.defaultLabel(old?.defaultValue) : nil,
                 width: 170, color: .tmMuted, struck: struck)
            keys(column, description: description)
        }
        .frame(height: 33)
        .background(rowBackground(column.mark, selected: selected))
        .overlay(alignment: .leading) { rowEdge(column.mark) }
        .overlay(alignment: .bottom) { if !last { Hairline(color: .tmLine2) } }
        .contentShape(Rectangle())
        .onTapGesture { grid.structureSelection = column.id }
        .contextMenu { columnMenu(column) }
    }

    @ViewBuilder private func columnMenu(_ column: StructureDraft.Column) -> some View {
        switch column.mark {
        case .new:
            Button("Remove New Column") { if let id = column.staged?.id { workspace.unstage(id) } }
        case .dropped:
            Button("Keep Column") { if let id = column.staged?.id { workspace.unstage(id) } }
        default:
            if let old = column.oldShape {
                Button("Drop Column") { workspace.dropColumn(old, in: grid.table) }
                    .disabled(column.loaded?.primaryKey == true)
            }
            if column.mark == .edited, let id = column.staged?.id {
                Button("Undo Changes") { workspace.unstage(id) }
            }
        }
    }

    @ViewBuilder private func keys(_ column: StructureDraft.Column, description: TableDescription) -> some View {
        HStack(spacing: 12) {
            switch column.mark {
            case .new:
                Text("new · not saved").font(.ui(12)).foregroundStyle(Color.tmOK)
            case .dropped:
                Text("dropped · not saved").font(.ui(12)).foregroundStyle(Color.tmBad)
            default:
                if column.loaded?.primaryKey == true {
                    HStack(spacing: 5) {
                        IconView(.key, size: 12, weight: 2).foregroundStyle(Color.tmWarn)
                        Text("primary key")
                    }
                }
                if let foreign = description.foreignKeys.first(where: { $0.column == column.loaded?.name }) {
                    HStack(spacing: 5) {
                        IconView(.reference, size: 12, weight: 2).foregroundStyle(Color.tmYou)
                        Text(verbatim: "\(foreign.referencedTable)\(foreign.referencedColumn.map { ".\($0)" } ?? "")")
                    }
                }
                ForEach(Array(description.checks.filter { $0.columns == [column.loaded?.name ?? ""] }.enumerated()), id: \.offset) { _, check in
                    Text(StructureText.check(check))
                }
            }
        }
        .font(.mono(11.5))
        .foregroundStyle(Color.tmText2)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Indexes

    private func indexesTable(_ draft: StructureDraft) -> some View {
        let measured = draft.indexes.contains { $0.loaded?.size != nil }
        let headers: [(LocalizedStringKey, CGFloat?)] = measured
            ? [("index", 250), ("columns", 200), ("kind", 150), ("size", 90), ("used", nil)]
            : [("index", 250), ("columns", 200), ("kind", nil)]
        return Group {
            if draft.indexes.isEmpty {
                Text("No indexes.").font(.ui(13)).foregroundStyle(Color.tmMuted).padding(.vertical, 4)
            } else {
                BorderedTable(headers: headers) {
                    ForEach(draft.indexes) { index in
                        indexRow(index, measured: measured, last: index.id == draft.indexes.last?.id)
                    }
                }
            }
        }
    }

    private func indexRow(_ index: StructureDraft.Index, measured: Bool, last: Bool) -> some View {
        let selected = grid.structureSelection == index.id
        let struck = index.mark == .dropped
        let proposed = index.mark == .proposed
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                if let proposal = index.proposal {
                    Button {
                        workspace.openReview(selecting: proposal.id)
                    } label: {
                        IconView(.check, size: 12, weight: 2)
                            .foregroundStyle(Color.tmText2)
                            .frame(width: 22, height: 22)
                            .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.tmLine))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Review \(proposal.client)'s proposal")
                    .accessibilityLabel("Review proposed index")
                }
                Text(index.shape.name)
                    .font(.mono(12.5, proposed || selected ? .medium : .regular))
                    .foregroundStyle(proposed ? Color.tmAgentText : (struck ? Color.tmMuted : Color.tmText))
                    .strikethrough(struck)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(width: 250, alignment: .leading)
            cell(index.shape.columns.joined(separator: ", "), width: 200, color: .tmText, struck: struck)
            if measured {
                cell(StructureText.kind(index, dialect: workspace.dialect), width: 150, color: .tmMuted, struck: struck)
                cell(index.loaded?.size.map(StructureText.size) ?? "", width: 90, color: .tmMuted, struck: struck)
                usedCell(index)
            } else {
                cell(StructureText.kind(index, dialect: workspace.dialect), width: nil, color: .tmMuted, struck: struck)
            }
        }
        .frame(height: 33)
        .background(rowBackground(index.mark, selected: selected))
        .overlay(alignment: .leading) { rowEdge(index.mark) }
        .overlay(alignment: .bottom) { if !last { Hairline(color: .tmLine2) } }
        .contentShape(Rectangle())
        .onTapGesture { grid.structureSelection = index.id }
        .contextMenu { indexMenu(index) }
    }

    @ViewBuilder private func usedCell(_ index: StructureDraft.Index) -> some View {
        switch index.mark {
        case .proposed:
            Text(StructureText.proposedBy(index.proposal)).font(.ui(12.5)).foregroundStyle(Color.tmAgentText)
                .lineLimit(1).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
        case .new:
            Text("new · not saved").font(.ui(12)).foregroundStyle(Color.tmOK)
                .lineLimit(1).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
        case .dropped:
            Text("dropped · not saved").font(.ui(12)).foregroundStyle(Color.tmBad)
                .lineLimit(1).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
        default:
            cell(index.loaded?.scans.map(StructureText.scans) ?? "", width: nil, color: .tmMuted)
        }
    }

    @ViewBuilder private func indexMenu(_ index: StructureDraft.Index) -> some View {
        switch index.mark {
        case .new:
            Button("Remove New Index") { if let id = index.staged?.id { workspace.unstage(id) } }
        case .dropped:
            Button("Keep Index") { if let id = index.staged?.id { workspace.unstage(id) } }
        case .proposed:
            if let proposal = index.proposal {
                Button("Review Proposal") { workspace.openReview(selecting: proposal.id) }
            }
        default:
            Button("Drop Index") { workspace.dropIndex(index.shape, in: grid.table) }
                .disabled(index.loaded?.constraint == true)
        }
    }

    // MARK: Cells

    private func cell(_ text: String, was: String? = nil, width: CGFloat?, color: Color, weight: Font.Weight = .regular, struck: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let was {
                Text(was.isEmpty ? String(localized: "none") : was).foregroundStyle(Color.tmMuted).strikethrough()
            }
            Text(text)
                .fontWeight(weight)
                .foregroundStyle(was != nil ? Color.tmText : (struck ? Color.tmMuted : color))
                .strikethrough(struck)
        }
        .font(.mono(12.5))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: .leading)
        .background(was != nil ? Color.tmYouTint : Color.clear)
        .overlay(alignment: .leading) {
            if was != nil { Rectangle().fill(Color.tmYou).frame(width: 2) }
        }
    }

    private func rowBackground(_ mark: StructureDraft.Mark, selected: Bool) -> Color {
        if selected { return .tmYouTint }
        switch mark {
        case .new: return .tmOKTint
        case .proposed: return .tmAgentTint
        case .dropped: return Color.tmYouTint.opacity(0.6)
        default: return .clear
        }
    }

    @ViewBuilder private func rowEdge(_ mark: StructureDraft.Mark) -> some View {
        switch mark {
        case .new: Rectangle().fill(Color.tmOK).frame(width: 3)
        case .proposed: Rectangle().fill(Color.tmAgent).frame(width: 3)
        default: EmptyView()
        }
    }
}

/// A table drawn as in the design: rounded border, a header line, hairlines between rows.
struct BorderedTable<Rows: View>: View {
    let headers: [(LocalizedStringKey, CGFloat?)]
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(headers.indices, id: \.self) { index in
                    let header = headers[index]
                    Text(header.0)
                        .font(.ui(12, .semibold))
                        .foregroundStyle(Color.tmText2)
                        .padding(.horizontal, 10)
                        .frame(width: header.1, alignment: .leading)
                        .frame(maxWidth: header.1 == nil ? .infinity : nil, alignment: .leading)
                }
            }
            .frame(height: 32)
            .overlay(alignment: .bottom) { Hairline() }
            rows
        }
        .background(Color.tmWindow)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.tmLine))
    }
}

struct TableRowView<Content: View>: View {
    var last = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: 33)
            .overlay(alignment: .bottom) {
                if !last { Hairline(color: .tmLine2) }
            }
    }
}

/// Underlined view tabs under a title, as in the design ("Data", "Structure").
struct ViewTabs<Value: Hashable>: View {
    let options: [(value: Value, label: LocalizedStringKey)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 14) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.ui(13, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.tmText : Color.tmMuted)
                        .padding(.horizontal, 2)
                        .frame(height: 34)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? Color.tmText : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
