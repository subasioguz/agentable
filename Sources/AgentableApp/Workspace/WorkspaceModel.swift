import AppKit
import Foundation
import Observation
import AgentableCore

enum WorkspaceTab: Hashable {
    case table(TableRef)
    case review
}

/// How a staged change reads in the list of changes, beyond its SQL: "Copy of 84209", or a few
/// values of a row you deleted.
struct ChangeNote: Equatable {
    var title: String?
    var detail: String?
}

/// A query saved as a `.sql` file in the connection's query folder.
struct SavedQuery: Identifiable, Hashable {
    var url: URL
    var modified: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// One open connection: the person's read-only session, the schema, open tables, staged edits and
/// what agents are doing on it.
@MainActor
@Observable
final class WorkspaceModel {
    enum Status: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    let profile: ConnectionProfile
    @ObservationIgnored weak var app: AppModel?

    private(set) var status: Status = .connecting
    @ObservationIgnored private(set) var browser: TableBrowser?
    private(set) var tables: [TableSummary] = []
    private(set) var estimates: [TableRef: Int] = [:]
    private(set) var descriptions: [TableRef: TableDescription] = [:]
    private(set) var serverVersion: String?

    var expanded: Set<TableRef> = []
    var railFilter = ""
    private(set) var tabs: [WorkspaceTab] = []
    var selected: WorkspaceTab?
    @ObservationIgnored private var grids: [TableRef: GridModel] = [:]

    /// The person's edits, waiting for review.
    private(set) var staged: [RowChange] = []
    private(set) var changeNotes: [UUID: ChangeNote] = [:]
    /// Staged edits and proposals left out of the next apply (ids as strings).
    var excluded: Set<String> = []
    var reviewSelection: String?
    var showSession = Defaults.string("showSession") != "no" {
        didSet { Defaults.set(showSession ? "yes" : "no", "showSession") }
    }
    var showPalette = false
    /// The row panel replaces the session panel while it is open.
    var showRow = false
    /// The list of your changes under the pending bar.
    var showChangeList = Defaults.string("changeList") != "no" {
        didSet { Defaults.set(showChangeList ? "yes" : "no", "changeList") }
    }
    /// Foreign keys pointing at each table, read once.
    private(set) var incoming: [TableRef: [IncomingReference]] = [:]
    /// Queries saved for this connection, newest first.
    private(set) var savedQueries: [SavedQuery] = []
    /// A readable name for rows that foreign keys point at ("Priya Raman" for customers 5).
    @ObservationIgnored private var rowLabels: [String: String] = [:]
    /// Production only: the pending bar is showing the SQL of your edits before they run.
    var confirmingSave = false
    private(set) var applying = false
    var notice: String?

    @ObservationIgnored private var feedRevision = -1
    /// The table to open first.
    @ObservationIgnored var preferredTable: String?

    init(profile: ConnectionProfile, app: AppModel) {
        self.profile = profile
        self.app = app
    }

    var dialect: SQLDialect { profile.engine.sqlDialect }

    // MARK: Agents

    var pending: [Proposal] { app?.feed.pending(on: profile.name) ?? [] }
    /// Agents' suggestions for this connection's saved queries.
    var suggestions: [SQLSuggestion] { app?.feed.suggestions(on: profile.name) ?? [] }
    var events: [LoggedEvent] { app?.feed.events(on: profile.name) ?? [] }
    var presence: [AgentPresence] { app?.feed.presence(on: profile.name) ?? [] }

    /// Pending proposals and staged edits together.
    var changeCount: Int { staged.count + pending.count }
    var includedCount: Int {
        staged.filter { !excluded.contains($0.id.uuidString) }.count + pending.filter { !excluded.contains($0.id) }.count
    }

    // MARK: Lifecycle

    func connect() async {
        guard let app else { return }
        status = .connecting
        do {
            let password = try app.secrets.password(for: profile.id)
            let session = try await app.sessions.open(profile, password: password, readOnly: true)
            browser = TableBrowser(session: session, engine: profile.engine)
            serverVersion = await version(session)
            status = .ready
            await loadSchema()
            let rules = profile.rules
            let preferred = tables.first { $0.name == preferredTable }
            if selected == nil, let first = preferred ?? tables.first(where: { $0.kind == .table && !AgentPolicy.isHidden(table: $0.name, rules: rules) }) ?? tables.first {
                open(TableRef(first))
            }
        } catch {
            status = .failed("\(error)")
        }
    }

    func close() {
        let session = browser?.session
        browser = nil
        grids.removeAll()
        if let session { Task { await session.close() } }
    }

    func loadSchema() async {
        guard let browser else { return }
        do {
            tables = try await browser.session.tables()
            estimates = (try? await browser.rowEstimates(tables)) ?? [:]
        } catch {
            let detail = "\(error)"
            notice = String(localized: "Could not read the schema: \(detail)")
        }
    }

    private func version(_ session: any DatabaseSession) async -> String? {
        let sql = profile.engine == .postgres ? "SHOW server_version" : "SELECT sqlite_version()"
        let result = try? await session.run(sql, options: QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(5)))
        guard let value = result?.rows.first?.first?.displayText else { return nil }
        let short = value.split(separator: " ").first.map(String.init) ?? value
        return "\(profile.engine == .postgres ? "postgres" : "sqlite") \(short)"
    }

    func describe(_ table: TableRef) async -> TableDescription? {
        if let known = descriptions[table] { return known }
        guard let browser else { return nil }
        let description = try? await browser.session.describe(table: table.path)
        descriptions[table] = description
        return description
    }

    // MARK: Tabs

    func open(_ table: TableRef) {
        if !tabs.contains(.table(table)) { tabs.append(.table(table)) }
        selected = .table(table)
        Defaults.set(table.name, "lastTable.\(profile.id.uuidString)")
    }

    func openReview(selecting id: String? = nil) {
        if !tabs.contains(.review) { tabs.append(.review) }
        selected = .review
        if let id { reviewSelection = id }
    }

    func closeTab(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if case .table(let table) = tab { grids[table] = nil }
        if selected == tab {
            selected = tabs.indices.contains(index) ? tabs[index] : tabs.last
        }
    }

    func grid(for table: TableRef) -> GridModel {
        if let grid = grids[table] { return grid }
        let grid = GridModel(table: table, workspace: self)
        grids[table] = grid
        Task { await grid.start() }
        return grid
    }

    func reloadCurrent() {
        if let table = currentTable { grids[table]?.reload() }
        Task { await loadSchema() }
    }

    var currentTable: TableRef? {
        if case .table(let table) = selected { return table }
        return nil
    }

    func defaultOrderChanged() {
        for grid in grids.values { grid.defaultOrderChanged() }
    }

    /// Called when the activity feed changes, so open grids redraw agent marks.
    func feedChanged() {
        guard let revision = app?.feed.revision, revision != feedRevision else { return }
        feedRevision = revision
        excluded = excluded.filter { id in staged.contains { $0.id.uuidString == id } || pending.contains { $0.id == id } }
        for grid in grids.values { grid.overlaysChanged() }
    }

    // MARK: Staged edits

    /// The window's undo manager: ⌘Z steps back through staged changes until they are saved.
    private var undoManager: UndoManager? {
        (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })?.undoManager
    }

    /// Runs `body`, which changes staged edits, as one undo step named `name` ("Undo Drop Column").
    func recordingUndo(_ name: String.LocalizationValue, _ body: () -> Void) {
        let before = staged
        let notesBefore = changeNotes
        body()
        guard staged != before else { return }
        registerUndo(restoring: before, notes: notesBefore, name: String(localized: name))
        stagedChanged(Set(before.map(\.table)).union(staged.map(\.table)))
    }

    private func registerUndo(restoring old: [RowChange], notes: [UUID: ChangeNote], name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let current = target.staged
                let currentNotes = target.changeNotes
                target.staged = old
                target.changeNotes = notes
                target.registerUndo(restoring: current, notes: currentNotes, name: name)
                target.stagedChanged(Set(old.map(\.table)).union(current.map(\.table)))
            }
        }
        undoManager.setActionName(name)
    }

    private func stagedChanged(_ tables: Set<TableRef>) {
        changeNotes = changeNotes.filter { id, _ in staged.contains { $0.id == id } }
        for grid in grids.values where tables.contains(grid.table) { grid.overlaysChanged() }
    }

    /// Adds or merges an edit. Edits to the same row combine; changing a value back drops it.
    /// New rows never merge. Call inside `recordingUndo`.
    func stage(_ change: RowChange, note: ChangeNote? = nil) {
        if let note { changeNotes[change.id] = note }
        if !change.mergesByRow {
            staged.append(change)
        } else if let index = staged.firstIndex(where: { $0.table == change.table && $0.key == change.key }) {
            var existing = staged[index]
            switch (existing.kind, change.kind) {
            case (.update(var columns), .update(let new)):
                for item in new {
                    if let at = columns.firstIndex(where: { $0.column == item.column }) {
                        columns[at].new = item.new
                        if columns[at].new == columns[at].old { columns.remove(at: at) }
                    } else if item.new != item.old {
                        columns.append(item)
                    }
                }
                if columns.isEmpty {
                    staged.remove(at: index)
                } else {
                    existing.kind = .update(columns)
                    staged[index] = existing
                }
            default:
                existing.kind = change.kind
                staged[index] = existing
            }
        } else {
            if case .update(let columns) = change.kind, columns.allSatisfy({ $0.new == $0.old }) { return }
            staged.append(change)
        }
    }

    /// Sets (or with `nil` clears) one value of a new row. `order` keeps values in column order.
    func updateInsert(_ id: UUID, column: String, value: CellValue?, order: [String]) {
        guard let index = staged.firstIndex(where: { $0.id == id }), case .insert(var values) = staged[index].kind else { return }
        if let value {
            if let at = values.firstIndex(where: { $0.column == column }) { values[at].value = value } else { values.append(KeyValue(column: column, value: value)) }
        } else {
            values.removeAll { $0.column == column }
        }
        values.sort { (order.firstIndex(of: $0.column) ?? .max) < (order.firstIndex(of: $1.column) ?? .max) }
        guard staged[index].kind != .insert(values) else { return }
        recordingUndo("Edit") { staged[index].kind = .insert(values) }
    }

    func unstage(_ id: UUID) {
        let name: String.LocalizationValue = staged.first { $0.id == id }?.isInsert == true ? "Remove New Row" : "Undo Change"
        recordingUndo(name) { staged.removeAll { $0.id == id } }
    }

    func discardStaged() {
        recordingUndo("Discard Changes") { staged.removeAll() }
    }

    /// Saved changes can't be undone from here any more.
    private func forgetUndo() {
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: Structure changes

    /// Structure changes waiting for `table`, in the order they run.
    func schemaChanges(for table: TableRef) -> [RowChange] {
        staged.filter { $0.table == table && $0.schemaChange != nil }
    }

    /// Adds a column at the end of `table`, to be named in the side panel; returns its change.
    @discardableResult
    func addColumn(to table: TableRef) -> UUID {
        var taken = Set(descriptions[table]?.columns.map { $0.name.lowercased() } ?? [])
        for change in schemaChanges(for: table) {
            if case .addColumn(let column)? = change.schemaChange { taken.insert(column.name.lowercased()) }
        }
        let name = Self.unused("new_column", taken: taken)
        let change = RowChange(table: table, key: [], kind: .schema(.addColumn(ColumnShape(name: name, type: "text"))))
        recordingUndo("Add Column") { staged.append(change) }
        return change.id
    }

    /// Adds an index on `columns`; returns its change.
    @discardableResult
    func addIndex(to table: TableRef, columns: [String]) -> UUID {
        var taken = Set(descriptions[table]?.indexes.map { $0.name.lowercased() } ?? [])
        for change in schemaChanges(for: table) {
            if case .addIndex(let index)? = change.schemaChange { taken.insert(index.name.lowercased()) }
        }
        let name = Self.unused(IndexShape.suggestedName(table: table.name, columns: columns, unique: false), taken: taken)
        let change = RowChange(table: table, key: [], kind: .schema(.addIndex(IndexShape(name: name, columns: columns))))
        recordingUndo("Add Index") { staged.append(change) }
        return change.id
    }

    private static func unused(_ base: String, taken: Set<String>) -> String {
        var name = base
        var number = 2
        while taken.contains(name.lowercased()) {
            name = "\(base)_\(number)"
            number += 1
        }
        return name
    }

    /// Changes a new column or index before it is saved.
    func updateStagedSchema(_ id: UUID, _ change: SchemaChange) {
        guard let index = staged.firstIndex(where: { $0.id == id }), staged[index].kind != .schema(change) else { return }
        recordingUndo(change.columnName != nil ? "Edit Column" : "Edit Index") { staged[index].kind = .schema(change) }
    }

    /// Changes an existing column. Edits of one column combine; changing it back drops the edit.
    func editColumn(_ old: ColumnShape, to new: ColumnShape, in table: TableRef) {
        recordingUndo("Change Column") {
            if let index = staged.firstIndex(where: { $0.table == table && Self.changes(column: old.name, $0) }) {
                if old == new { staged.remove(at: index) } else { staged[index].kind = .schema(.alterColumn(old: old, new: new)) }
            } else if old != new {
                staged.append(RowChange(table: table, key: [], kind: .schema(.alterColumn(old: old, new: new))))
            }
        }
    }

    /// Drops an existing column, in place of any edit waiting for it.
    func dropColumn(_ column: ColumnShape, in table: TableRef) {
        recordingUndo("Drop Column") {
            if let index = staged.firstIndex(where: { $0.table == table && Self.changes(column: column.name, $0) }) {
                staged[index].kind = .schema(.dropColumn(column))
            } else {
                staged.append(RowChange(table: table, key: [], kind: .schema(.dropColumn(column))))
            }
        }
    }

    func dropIndex(_ index: IndexShape, in table: TableRef) {
        guard !staged.contains(where: { $0.table == table && $0.schemaChange == .dropIndex(index) }) else { return }
        recordingUndo("Drop Index") { staged.append(RowChange(table: table, key: [], kind: .schema(.dropIndex(index)))) }
    }

    /// The staged edit or drop of an existing column.
    nonisolated static func changes(column: String, _ change: RowChange) -> Bool {
        switch change.schemaChange {
        case .alterColumn(let old, _)?: old.name == column
        case .dropColumn(let dropped)?: dropped.name == column
        default: false
        }
    }

    /// Structure changed on the server: read it again everywhere it shows.
    private func structureApplied(_ tables: Set<TableRef>, everywhere: Bool) async {
        descriptions.removeAll()
        incoming.removeAll()
        rowLabels.removeAll()
        for grid in grids.values where everywhere || tables.contains(grid.table) {
            await grid.structureChanged()
        }
        await loadSchema()
    }

    /// Whether an agent's proposal changes structure rather than rows.
    static func isDDL(_ proposal: Proposal, dialect: SQLDialect) -> Bool {
        let verb = SQLAnalyzer.statements(in: proposal.sql, dialect: dialect).first?.verb ?? ""
        return ["CREATE", "ALTER", "DROP"].contains(verb)
    }

    // MARK: Following foreign keys

    /// Opens `target` showing only rows whose `column` holds `value`, with a way back to `from`.
    func follow(to target: TableRef, column: String, value: CellValue, from: TableRef, key: String) {
        let category = descriptions[target]?.columns.first { $0.name == column }.map { ColumnCategory(typeName: $0.type) }
            ?? (value.isNumber ? .integer : .text)
        open(target)
        let grid = grid(for: target)
        var filter = TableFilter()
        filter.append(FilterCondition(column: column, category: category, op: .isAnyOf, values: [value]))
        grid.filterMode = .chips
        grid.search = ""
        grid.cameFrom = BackLink(table: from, key: key)
        grid.selectRows = IndexSet(integer: 0)
        grid.filter = filter
    }

    func goBack(from grid: GridModel) {
        guard let back = grid.cameFrom else { return }
        grid.cameFrom = nil
        open(back.table)
    }

    // MARK: Saved queries

    /// The saved queries next to connections.json.
    var queryLibrary: QueryLibrary? {
        app.map { QueryLibrary(profiles: $0.profileStore) }
    }

    /// `queries/<connection>`.
    var queriesFolder: URL? {
        queryLibrary?.folder(connection: profile.name)
    }

    /// Opens a saved query (or one an agent suggested under a new name) in the SQL tab of the
    /// table on screen.
    func openSavedQuery(_ name: String) {
        guard let library = queryLibrary, let url = try? library.url(connection: profile.name, name: name),
              let table = currentTable ?? tabs.compactMap({ if case .table(let table) = $0 { table } else { nil } }).first
                ?? tables.first.map(TableRef.init) else { return }
        open(table)
        let grid = grid(for: table)
        grid.viewTab = .sql
        grid.sql.open(url)
    }

    /// Puts an agent's suggestion in the editor: the document takes the text, the log notes it.
    func accept(_ suggestion: SQLSuggestion, in document: SQLDocument) {
        document.take(suggestion.sql)
        settle(suggestion, as: .accepted)
    }

    func dismiss(_ suggestion: SQLSuggestion) {
        settle(suggestion, as: .dismissed)
    }

    private func settle(_ suggestion: SQLSuggestion, as status: SQLSuggestion.Status) {
        guard let app else { return }
        Task {
            guard (try? await app.state.decide(suggestion: suggestion.id, status: status)) == true else { return }
            try? await app.state.record(AuditEvent(
                connection: profile.name, client: "you", action: status == .accepted ? .accepted : .dismissed,
                sql: status == .accepted ? suggestion.sql : "", detail: suggestion.query
            ))
            await app.feed.refresh()
        }
    }

    func reloadSavedQueries() {
        guard let folder = queriesFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            savedQueries = []
            return
        }
        savedQueries = files.filter { $0.pathExtension.lowercased() == "sql" }.map { url in
            SavedQuery(url: url, modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    var currentGrid: GridModel? {
        currentTable.map { grid(for: $0) }
    }

    /// The grid of an open table, without making one.
    func openGrid(_ table: TableRef) -> GridModel? {
        grids[table]
    }

    /// Adds an empty row to the open table (⌘I).
    func addRow() {
        guard let table = currentTable else { return }
        grid(for: table).addRow()
    }

    /// Columns a new row still needs a value for: not null, no default, not filled by the database.
    func missingValues(_ change: RowChange) -> [String] {
        guard case .insert(let values) = change.kind, let description = descriptions[change.table] else { return [] }
        let singleKey = description.columns.filter(\.primaryKey).count == 1
        let given = Set(values.map(\.column))
        return description.columns.filter {
            !$0.nullable && $0.defaultValue == nil && !given.contains($0.name)
                && !GridModel.isAutoValue($0, singleKey: singleKey, engine: profile.engine)
        }.map(\.name)
    }

    /// Foreign keys pointing at `table`, read once per table.
    func references(to table: TableRef) async -> [IncomingReference] {
        if let known = incoming[table] { return known }
        guard let browser else { return [] }
        let found = (try? await browser.session.references(to: table.path)) ?? []
        incoming[table] = found
        return found
    }

    /// The table a foreign key points at, as the app addresses it.
    func referencedTable(_ key: ForeignKeyInfo) -> TableRef {
        let schema = key.referencedSchema ?? tables.first { $0.name == key.referencedTable }?.schema
        return TableRef(schema: schema, name: key.referencedTable)
    }

    /// The column a foreign key points at: named, or the target's primary key.
    func referencedColumn(_ key: ForeignKeyInfo) async -> String? {
        if let column = key.referencedColumn { return column }
        return await describe(referencedTable(key))?.columns.first(where: \.primaryKey)?.name
    }

    /// A readable name for the row of `table` where `column` is `value`: its name, title or
    /// email column, or else its first text column.
    func rowLabel(_ table: TableRef, column: String, value: CellValue) async -> String? {
        let cacheKey = "\(table.path)\u{1F}\(column)\u{1F}\(value.displayText)"
        if let known = rowLabels[cacheKey] { return known.isEmpty ? nil : known }
        guard let browser, let description = await describe(table) else { return nil }
        let names = description.columns.map(\.name)
        let preferred = ["name", "full_name", "display_name", "title", "label", "email", "username", "number", "sku"]
        let labelColumn = preferred.first { names.contains($0) }
            ?? description.columns.first { ColumnCategory(typeName: $0.type) == .text && !$0.primaryKey && $0.name != column }?.name
        guard let labelColumn else { rowLabels[cacheKey] = ""; return nil }
        var filter = TableFilter()
        filter.append(FilterCondition(column: column, category: value.isNumber ? .integer : .text, op: .isAnyOf, values: [value]))
        let query = TableQuery(table: table, dialect: dialect, filter: filter)
        let result = try? await browser.page(query, offset: 0, limit: 1)
        let label = result.flatMap { TableBrowser.project($0, onto: [labelColumn]).first?.first }.flatMap { $0.isNull ? nil : $0.displayText }
        rowLabels[cacheKey] = label ?? ""
        return label
    }

    /// How many rows of `reference.table` point at `value`; `nil` when counting takes too long.
    func countReferencing(_ reference: IncomingReference, value: CellValue) async -> Int? {
        guard let browser else { return nil }
        var filter = TableFilter()
        filter.append(FilterCondition(column: reference.column, category: value.isNumber ? .integer : .text, op: .isAnyOf, values: [value]))
        let query = TableQuery(table: TableRef(schema: reference.schema, name: reference.table), dialect: dialect, filter: filter)
        return try? await browser.count(query, timeout: .seconds(3))
    }

    // MARK: Saving your own edits

    /// ⌘S. Your own edits save directly; production first shows their SQL. Agent proposals always
    /// go through the review screen.
    func save() {
        // On the Structure tab a field may still be in the middle of typing: it commits when it
        // loses focus, so let that land before saving.
        if currentTable.flatMap({ grids[$0] })?.viewTab == .structure,
           let window = NSApp.keyWindow, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                self?.saveNow()
            }
            return
        }
        saveNow()
    }

    private func saveNow() {
        if !pending.isEmpty {
            openReview()
        } else if !staged.isEmpty {
            if profile.environment == .production {
                confirmingSave = true
            } else {
                Task { await saveEdits() }
            }
        }
    }

    /// Applies only your staged edits, in one transaction.
    func saveEdits() async {
        guard let app, !applying, !staged.isEmpty else { return }
        let edits = staged
        applying = true
        defer { applying = false }
        do {
            try await app.review.apply(connection: profile.name, edits: edits, proposalIDs: [])
            staged.removeAll { change in edits.contains { $0.id == change.id } }
            forgetUndo()
            stagedChanged(Set(edits.map(\.table)))
            confirmingSave = false
            notice = nil
            await app.feed.refresh()
            let structural = Set(edits.filter { $0.schemaChange != nil }.map(\.table))
            if !structural.isEmpty { await structureApplied(structural, everywhere: false) }
            for table in Set(edits.map(\.table)).subtracting(structural) { grids[table]?.reload() }
        } catch {
            notice = "\(error)"
        }
    }

    // MARK: Review

    /// Applies included edits and proposals in one transaction, then reloads what changed.
    func applyIncluded() async {
        guard let app, !applying else { return }
        let edits = staged.filter { !excluded.contains($0.id.uuidString) }
        let proposals = pending.filter { !excluded.contains($0.id) }
        guard !edits.isEmpty || !proposals.isEmpty else { return }
        applying = true
        defer { applying = false }
        do {
            try await app.review.apply(connection: profile.name, edits: edits, proposalIDs: proposals.map(\.id))
            staged.removeAll { change in edits.contains { $0.id == change.id } }
            forgetUndo()
            stagedChanged(Set(edits.map(\.table)))
            await app.feed.refresh()
            let structural = Set(edits.filter { $0.schemaChange != nil }.map(\.table))
            let agentDDL = proposals.contains { Self.isDDL($0, dialect: dialect) }
            if !structural.isEmpty || agentDDL { await structureApplied(structural, everywhere: agentDDL) }
            let touched = Set(edits.map(\.table)).union(proposals.compactMap { $0.preview.map { TableRef(schema: $0.schema, name: $0.table) } })
            for grid in grids.values where !structural.contains(grid.table) && !agentDDL
                && (touched.contains(grid.table) || proposals.contains(where: { $0.preview == nil })) {
                grid.reload()
            }
            reviewSelection = nil
            if changeCount == 0, let first = tabs.first(where: { $0 != .review }) {
                closeTab(.review)
                selected = first
            }
            notice = nil
        } catch {
            notice = "\(error)"
        }
    }

    func reject(_ proposal: Proposal, note: String?) async {
        guard let app else { return }
        do {
            _ = try await app.review.reject(proposal.id, note: note)
            await app.feed.refresh()
            if reviewSelection == proposal.id { reviewSelection = nil }
            for grid in grids.values { grid.overlaysChanged() }
        } catch {
            notice = "\(error)"
        }
    }

    /// Drops the person's edits and turns down every waiting proposal. Narrowing, so no confirmation.
    func discardAll() async {
        discardStaged()
        for proposal in pending {
            await reject(proposal, note: "Discarded in the app")
        }
    }
}
