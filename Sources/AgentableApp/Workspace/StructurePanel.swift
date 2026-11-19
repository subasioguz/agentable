import SwiftUI
import AgentableCore

/// The Structure tab's side panel: the selected column or index, as on the canvas.
struct StructurePanel: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var grid: GridModel

    var body: some View {
        Group {
            if let description = grid.description, let item = grid.structureSelection {
                let draft = StructureDraft(
                    description: description, changes: workspace.schemaChanges(for: grid.table),
                    proposals: workspace.pending, dialect: workspace.dialect
                )
                if let column = draft.column(item) {
                    ColumnPanel(
                        workspace: workspace, grid: grid, column: column, description: description,
                        position: (draft.columns.firstIndex { $0.id == item } ?? 0) + 1, count: draft.columns.count,
                        proposals: draft.indexes.filter { $0.mark == .proposed }
                    )
                    .id(item)
                } else if let index = draft.index(item) {
                    IndexPanel(
                        workspace: workspace, grid: grid, index: index, description: description,
                        position: (draft.indexes.firstIndex { $0.id == item } ?? 0) + 1, count: draft.indexes.count
                    )
                    .id(item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tmPanel)
    }
}

// MARK: Column

private struct ColumnPanel: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var grid: GridModel
    let column: StructureDraft.Column
    let description: TableDescription
    let position: Int
    let count: Int
    let proposals: [StructureDraft.Index]

    @State private var name = ""
    @State private var type = ""
    @State private var defaultText = ""
    @State private var allowsEmpty = true
    @State private var spread: [ValueCount] = []
    @State private var total = 0
    @State private var referencedBy: [IncomingReference] = []
    /// Typed but not committed yet; committed when the panel closes.
    @State private var dirty = false
    @FocusState private var focus: Field?

    enum Field { case name, type, defaultValue }

    private var sqlite: Bool { workspace.dialect == .sqlite }
    private var dropped: Bool { column.mark == .dropped }
    /// SQLite changes a saved column only by renaming it.
    private var renameOnly: Bool { sqlite && column.mark != .new }
    private var loadedName: String? { column.loaded?.name }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(column.shape.name).font(.mono(15, .semibold)).foregroundStyle(Color.tmText).lineLimit(1)
                    (column.mark == .new ? Text("new column") : Text("column \(position) of \(count)"))
                        .font(.ui(12)).foregroundStyle(Color.tmMuted)
                }
                fields
                notes
                allowedValues
                inTheData
                usedBy
                action
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { ProductionNote(workspace: workspace) }
        .onAppear {
            load()
            if column.mark == .new { focus = .name }
        }
        .onChange(of: column.shape) { if focus == nil { load() } }
        .onChange(of: focus) { old, _ in if old != nil { commit() } }
        .onChange(of: name) { if focus != nil { dirty = true } }
        .onChange(of: type) { if focus != nil { dirty = true } }
        .onChange(of: defaultText) { if focus != nil { dirty = true } }
        .onDisappear { if dirty { commit() } }
        .task(id: column.id) { await loadFacts() }
    }

    // MARK: Fields

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                labeled("Name") {
                    FieldBox(height: 32, focused: focus == .name) {
                        TextField("name", text: $name).textFieldStyle(.plain).font(.mono(12.5))
                            .focused($focus, equals: .name).onSubmit(commit)
                    }
                    .disabled(dropped)
                }
                labeled("Type") {
                    ComboField(placeholder: "text", text: $type, options: Self.types(workspace.dialect), focused: focus == .type, onCommit: commit)
                        .focused($focus, equals: .type)
                        .disabled(dropped || renameOnly)
                        .opacity(renameOnly && !dropped ? 0.5 : 1)
                }
            }
            GridRow {
                labeled("Default") {
                    FieldBox(height: 32, focused: focus == .defaultValue) {
                        TextField(column.loaded?.identity == true ? "identity" : "none", text: $defaultText)
                            .textFieldStyle(.plain).font(.mono(12.5))
                            .focused($focus, equals: .defaultValue).onSubmit(commit)
                    }
                    .disabled(dropped || renameOnly || column.loaded?.identity == true)
                    .opacity((renameOnly || column.loaded?.identity == true) && !dropped ? 0.5 : 1)
                }
                labeled("Allows empty") {
                    HStack(spacing: 8) {
                        ToggleSwitch(isOn: Binding(get: { allowsEmpty }, set: { allowsEmpty = $0; commit() }))
                        Text(StructureText.yesNo(allowsEmpty)).font(.ui(13)).foregroundStyle(Color.tmMuted)
                    }
                    .frame(height: 32)
                    .disabled(dropped || renameOnly || column.loaded?.primaryKey == true)
                    .opacity((renameOnly || column.loaded?.primaryKey == true) && !dropped ? 0.5 : 1)
                }
            }
        }
        .opacity(dropped ? 0.5 : 1)
    }

    private func labeled<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.ui(12, .medium)).foregroundStyle(Color.tmText2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Why the change can't run, and what the database will refuse.
    @ViewBuilder private var notes: some View {
        let problem = column.staged?.schemaChange?.problem(dialect: workspace.dialect)
        let views = loadedName.flatMap { description.views[$0] } ?? []
        let retyped = column.mark == .edited && column.oldShape?.type != column.shape.type
        if let problem {
            Text(problem).font(.ui(12)).foregroundStyle(Color.tmBad).fixedSize(horizontal: false, vertical: true)
        } else if retyped && !views.isEmpty {
            let list = views.joined(separator: ", ")
            (views.count == 1
                ? Text("\(list) reads this column, so PostgreSQL won't change its type.")
                : Text("\(list) read this column, so PostgreSQL won't change its type."))
                .font(.ui(12)).foregroundStyle(Color.tmWarn).fixedSize(horizontal: false, vertical: true)
        } else if renameOnly && !dropped {
            Text("SQLite can only rename a saved column.").font(.ui(12)).foregroundStyle(Color.tmMuted)
        }
    }

    // MARK: Facts

    @ViewBuilder private var allowedValues: some View {
        let values = description.checks.filter { $0.columns == [loadedName ?? ""] }.compactMap(\.allowedValues).first
        if let values {
            section("Allowed values") {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value).font(.mono(12)).foregroundStyle(Color.tmText)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Color.tmChip, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    /// The most common values and their share, when a few values make up a real part of the table.
    @ViewBuilder private var inTheData: some View {
        let top = spread.first?.count ?? 0
        if total > 0, top * 100 >= total {
            section("In the data") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(Array(spread.enumerated()), id: \.offset) { _, item in
                        GridRow {
                            Text(item.value.isNull ? String(localized: "empty") : GridStyle.display(item.value))
                                .font(.mono(12.5)).foregroundStyle(item.value.isNull ? Color.tmMuted : Color.tmText)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Capsule().fill(Color.tmLine2).frame(width: 70, height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color.tmMuted.opacity(0.55))
                                        .frame(width: max(2, 70 * CGFloat(item.count) / CGFloat(max(top, 1))), height: 4)
                                }
                            Text(Self.share(item.count, of: total))
                                .font(.mono(11.5)).foregroundStyle(Color.tmMuted)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var usedBy: some View {
        let name = loadedName ?? ""
        let indexes = description.indexes.filter { $0.columns.contains { Self.columnOf($0) == name } }
        let checks = description.checks.filter { $0.columns.contains(name) }
        let views = description.views[name] ?? []
        let references = referencedBy.filter { ($0.referencedColumn ?? description.columns.first(where: \.primaryKey)?.name) == name }
        let proposed = proposals.filter { $0.shape.columns.contains { Self.columnOf($0) == name } }
        if column.loaded != nil, !(indexes.isEmpty && checks.isEmpty && views.isEmpty && references.isEmpty && proposed.isEmpty) {
            section("Used by", spacing: 6) {
                ForEach(checks, id: \.self) { usage("check", $0.name ?? $0.definition) }
                ForEach(views, id: \.self) { usage("view", $0) }
                ForEach(indexes, id: \.name) { usage($0.constraint ? "key" : "index", $0.name) }
                ForEach(references, id: \.self) { usage("foreign key", "\($0.table).\($0.column)") }
                ForEach(proposed) { usage("proposed index", $0.shape.name, agent: true) }
            }
        }
    }

    private func usage(_ kind: LocalizedStringKey, _ name: String, agent: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(kind).font(.ui(13))
            Text(name).font(.mono(12)).lineLimit(1)
        }
        .foregroundStyle(agent ? Color.tmAgentText : Color.tmText2)
    }

    @ViewBuilder private var action: some View {
        switch column.mark {
        case .new:
            Button("Remove new column") { if let id = column.staged?.id { workspace.unstage(id) } }
                .buttonStyle(.text(height: 28, size: 12.5, color: .tmBad))
                .padding(.leading, -8)
        case .dropped:
            Button("Keep column") { if let id = column.staged?.id { workspace.unstage(id) } }
                .buttonStyle(.text(height: 28, size: 12.5))
                .padding(.leading, -8)
        default:
            if let old = column.oldShape, column.loaded?.primaryKey != true {
                Button("Drop column") { workspace.dropColumn(old, in: grid.table) }
                    .buttonStyle(.text(height: 28, size: 12.5, color: .tmBad))
                    .padding(.leading, -8)
            }
        }
    }

    private func section<Content: View>(_ title: String.LocalizationValue, spacing: CGFloat = 8, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            SectionLabel(text: title)
            content()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline(color: .tmLine2) }
    }

    // MARK: Editing

    private func load() {
        name = column.shape.name
        type = StructureText.type(column.shape.type)
        defaultText = column.loaded?.identity == true ? "" : StructureText.defaultLabel(column.shape.defaultValue)
        allowsEmpty = column.shape.nullable
    }

    /// Stages what the fields say. Text that still reads like the current or loaded value keeps
    /// the database's own spelling, so nothing changes by accident.
    private func commit() {
        dirty = false
        guard !dropped else { return }
        var new = column.shape
        let old = column.oldShape
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty { name = new.name } else { new.name = trimmedName }

        let trimmedType = type.trimmingCharacters(in: .whitespaces)
        if trimmedType.isEmpty {
            type = StructureText.type(new.type)
        } else if let old, trimmedType == StructureText.type(old.type) {
            new.type = old.type
        } else if trimmedType != StructureText.type(new.type) {
            new.type = trimmedType
        }

        let trimmedDefault = defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let old, trimmedDefault == StructureText.defaultLabel(old.defaultValue) {
            new.defaultValue = old.defaultValue
        } else if trimmedDefault != StructureText.defaultLabel(new.defaultValue) {
            new.defaultValue = trimmedDefault.isEmpty ? nil : trimmedDefault
        }
        new.nullable = allowsEmpty

        if column.mark == .new {
            if let id = column.staged?.id { workspace.updateStagedSchema(id, .addColumn(new)) }
        } else if let old {
            workspace.editColumn(old, to: new, in: grid.table)
        }
    }

    private func loadFacts() async {
        guard let name = loadedName, let browser = workspace.browser else { return }
        referencedBy = await workspace.references(to: grid.table)
        let category = ColumnCategory(typeName: column.loaded?.type ?? "")
        guard category != .json && category != .binary else { return }
        total = grid.knownCount ?? workspace.estimates[grid.table] ?? 0
        let query = TableQuery(table: grid.table, dialect: workspace.dialect)
        spread = (try? await browser.valueCounts(query, column: name, excluding: nil, limit: 5)) ?? []
    }

    // MARK: Words

    static func types(_ dialect: SQLDialect) -> [String] {
        dialect == .postgres
            ? ["text", "varchar(255)", "integer", "bigint", "numeric(10,2)", "boolean", "date", "timestamptz", "jsonb", "uuid"]
            : ["text", "integer", "real", "numeric", "blob"]
    }

    /// "61%", "<1%" (Turkish: "%61", "<%1")
    static func share(_ count: Int, of total: Int) -> String {
        let fraction = Double(count) / Double(max(total, 1))
        let style = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0)).locale(L10n.locale)
        return fraction < 0.01 ? "<" + 0.01.formatted(style) : fraction.formatted(style)
    }

    /// "created_at" for "created_at DESC".
    static func columnOf(_ indexColumn: String) -> String {
        let first = indexColumn.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? indexColumn
        return first.hasPrefix("\"") && first.hasSuffix("\"") && first.count > 1 ? String(first.dropFirst().dropLast()) : first
    }
}

// MARK: Index

private struct IndexPanel: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var grid: GridModel
    let index: StructureDraft.Index
    let description: TableDescription
    let position: Int
    let count: Int

    @State private var name = ""
    @State private var dirty = false
    @FocusState private var naming: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(index.shape.name).font(.mono(15, .semibold))
                        .foregroundStyle(index.mark == .proposed ? Color.tmAgentText : Color.tmText).lineLimit(1)
                    Text(subtitle).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
                }
                if index.mark == .new {
                    editor
                } else {
                    facts
                }
                if let problem = index.staged?.schemaChange?.problem(dialect: workspace.dialect), index.mark == .new {
                    Text(problem).font(.ui(12)).foregroundStyle(Color.tmBad).fixedSize(horizontal: false, vertical: true)
                }
                action
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { ProductionNote(workspace: workspace) }
        .onAppear {
            name = index.shape.name
            if index.mark == .new { naming = true }
        }
        .onChange(of: index.shape.name) { if !naming { name = index.shape.name } }
        .onChange(of: naming) { old, _ in if old { rename() } }
        .onChange(of: name) { if naming { dirty = true } }
        .onDisappear { if dirty { rename() } }
    }

    private var subtitle: String {
        switch index.mark {
        case .new: String(localized: "new index")
        case .proposed: StructureText.proposedBy(index.proposal)
        default: String(localized: "index \(position) of \(count)")
        }
    }

    // MARK: New index

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Name") {
                FieldBox(height: 32, focused: naming) {
                    TextField("name", text: $name).textFieldStyle(.plain).font(.mono(12.5))
                        .focused($naming).onSubmit(rename)
                }
            }
            labeled("Columns") {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(index.shape.columns, id: \.self) { column in
                        Token(text: column, onRemove: { setColumns(index.shape.columns.filter { $0 != column }) })
                    }
                    let remaining = description.columns.map(\.name).filter { !index.shape.columns.contains($0) }
                    if !remaining.isEmpty {
                        SelectBox(height: 24, width: nil) {
                            ForEach(remaining, id: \.self) { column in
                                Button(column) { setColumns(index.shape.columns + [column]) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                IconView(.plus, size: 12)
                                Text("Column").font(.ui(12))
                            }
                            .foregroundStyle(Color.tmText2)
                        }
                        .fixedSize()
                    }
                }
            }
            labeled("Unique") {
                HStack(spacing: 8) {
                    ToggleSwitch(isOn: Binding(get: { index.shape.unique }, set: { unique in
                        var shape = index.shape
                        shape.unique = unique
                        stage(shape)
                    }))
                    Text(StructureText.yesNo(index.shape.unique)).font(.ui(13)).foregroundStyle(Color.tmMuted)
                }
            }
        }
    }

    private func labeled<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.ui(12, .medium)).foregroundStyle(Color.tmText2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// New columns rename an index that still has its suggested name.
    private func setColumns(_ columns: [String]) {
        var shape = index.shape
        let suggested = IndexShape.suggestedName(table: grid.table.name, columns: shape.columns, unique: shape.unique)
        shape.columns = columns
        if shape.name.hasPrefix(suggested), !columns.isEmpty {
            shape.name = IndexShape.suggestedName(table: grid.table.name, columns: columns, unique: shape.unique)
        }
        stage(shape)
    }

    private func rename() {
        dirty = false
        guard index.mark == .new else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            name = index.shape.name
            return
        }
        var shape = index.shape
        shape.name = trimmed
        stage(shape)
    }

    private func stage(_ shape: IndexShape) {
        if let id = index.staged?.id { workspace.updateStagedSchema(id, .addIndex(shape)) }
    }

    // MARK: Saved or proposed index

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            fact("Columns", index.shape.columns.joined(separator: ", "))
            fact("Kind", StructureText.kind(index, dialect: workspace.dialect).isEmpty ? String(localized: "index") : StructureText.kind(index, dialect: workspace.dialect))
            if let size = index.loaded?.size { fact("Size", StructureText.size(size)) }
            if let scans = index.loaded?.scans { fact("Used", StructureText.scans(scans)) }
        }
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).font(.ui(12, .medium)).foregroundStyle(Color.tmText2)
            Text(value).font(.mono(12.5)).foregroundStyle(Color.tmText).lineLimit(2)
        }
    }

    @ViewBuilder private var action: some View {
        switch index.mark {
        case .new:
            Button("Remove new index") { if let id = index.staged?.id { workspace.unstage(id) } }
                .buttonStyle(.text(height: 28, size: 12.5, color: .tmBad))
                .padding(.leading, -8)
        case .dropped:
            Button("Keep index") { if let id = index.staged?.id { workspace.unstage(id) } }
                .buttonStyle(.text(height: 28, size: 12.5))
                .padding(.leading, -8)
        case .proposed:
            if let proposal = index.proposal {
                if let reason = proposal.reason {
                    Text(reason).font(.ui(12.5)).foregroundStyle(Color.tmText2).fixedSize(horizontal: false, vertical: true)
                }
                Button("Review proposal") { workspace.openReview(selecting: proposal.id) }
                    .buttonStyle(.secondary(height: 30))
            }
        default:
            if index.loaded?.constraint == true {
                Text(index.shape.unique && description.columns.filter(\.primaryKey).map(\.name) == index.shape.columns
                     ? "Made by the primary key; it goes with the key."
                     : "Made by a unique constraint; it goes with the constraint.")
                    .font(.ui(12)).foregroundStyle(Color.tmMuted).fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Drop index") { workspace.dropIndex(index.shape, in: grid.table) }
                    .buttonStyle(.text(height: 28, size: 12.5, color: .tmBad))
                    .padding(.leading, -8)
            }
        }
    }
}

/// On production, at the foot of the panel: schema changes are shown before they run.
private struct ProductionNote: View {
    let workspace: WorkspaceModel

    var body: some View {
        if workspace.profile.environment == .production {
            HStack(alignment: .top, spacing: 8) {
                IconView(.access, size: 14).foregroundStyle(Color.tmMuted).padding(.top, 1)
                Text("Production: every schema change shows its DDL and lock level before it runs.")
                    .font(.ui(12)).foregroundStyle(Color.tmText2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tmSide, in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
            .background(Color.tmPanel)
        }
    }
}
