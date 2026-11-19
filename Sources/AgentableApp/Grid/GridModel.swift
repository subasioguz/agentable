import Foundation
import Observation
import AgentableCore

struct GridColumn: Identifiable, Hashable {
    var name: String
    var type: String
    var category: ColumnCategory
    var isPrimaryKey: Bool
    var foreignTable: String?
    var nullable: Bool
    var width: Double
    var hidden = false
    var foreignKey: ForeignKeyInfo? = nil
    var defaultValue: String? = nil
    /// The database fills it in on insert: an identity, a sequence or SQLite's row id.
    var autoValue = false

    var id: String { name }

    var isNumeric: Bool { category.isNumeric }
    /// Numbers read right-aligned; keys stay on the left like the names they stand for.
    var alignsRight: Bool { isNumeric && !isPrimaryKey && foreignTable == nil }
    /// Digits after the point for `numeric(p,s)` columns, so 93.9 shows as 93.90.
    var scale: Int? {
        guard category == .decimal, let open = type.firstIndex(of: ","), let close = type.firstIndex(of: ")") else { return nil }
        return Int(type[type.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }
}

enum FilterMode: String, Hashable {
    case chips, advanced, sql
}

/// The views of one open table, as tabs under its name.
enum TableTab: Hashable {
    case data, structure, sql
}

/// What is selected on the Structure tab. New columns and indexes go by their staged change, so
/// renaming them keeps the selection.
enum StructureItem: Hashable {
    case column(String)
    case newColumn(UUID)
    case index(String)
    case newIndex(UUID)
}

/// What one cell shows beyond its value.
enum CellMark: Equatable {
    case none
    /// The person changed it; waiting for review.
    case edited(was: CellValue, now: CellValue)
    /// An agent proposes a new value.
    case proposed(was: CellValue, now: String?)
}

/// What a row shows beyond its cells.
struct RowMarks: Equatable {
    var editedByYou = false
    var deletedByYou = false
    /// A row you added that is not saved yet.
    var isNew = false
    /// An agent proposes changing this row; the proposal's id.
    var proposal: String?
    var deletedByAgent = false
}

/// Where a table was opened from by following a foreign key, for the way back.
struct BackLink: Equatable {
    var table: TableRef
    /// The key of the row it came from, "5".
    var key: String
}

/// The rows of one table view, loaded a page at a time as the grid asks for them.
@MainActor
@Observable
final class GridModel {
    let table: TableRef
    @ObservationIgnored weak var workspace: WorkspaceModel?

    private(set) var description: TableDescription?
    var columns: [GridColumn] = [] {
        didSet { if columns != oldValue { layoutChanged() } }
    }
    var filter = TableFilter() {
        didSet { if filter != oldValue { page = 0; reload() } }
    }
    var sort: [SortKey] = [] {
        didSet {
            guard sort != oldValue else { return }
            if !settingSort { sortIsDefault = false }
            if !holdReload { page = 0; reload() }
            layoutChanged()
        }
    }
    /// The sort came from the default order, not from the person.
    @ObservationIgnored private var sortIsDefault = true
    @ObservationIgnored private var settingSort = false
    @ObservationIgnored private var holdReload = false
    /// Changes are remembered only once the remembered layout has been put on the columns.
    @ObservationIgnored private var layoutReady = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    var filterMode: FilterMode = .chips
    /// A new chip whose value picker opens as soon as the chip is on screen.
    @ObservationIgnored var pickerToOpen: UUID?
    /// Quick search across every column, on top of the filters.
    var search = "" {
        didSet {
            guard search != oldValue else { return }
            let text = search
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                if text == search { page = 0; reload() }
            }
        }
    }

    // MARK: Pages

    /// The page on screen, from 0. Rows load in chunks of `pageSize` whatever the page size is.
    private(set) var page = 0
    /// Rows per page, remembered across tables.
    private(set) var rowsPerPage = GridModel.savedRowsPerPage
    /// The sizes offered as buttons; any size in `pageSizeRange` can be typed.
    static let pageSizes = [10, 50, 100, 200, 500, 1_000]
    static let pageSizeRange = 1...10_000
    private static var savedRowsPerPage: Int {
        let saved = Int(Defaults.string("rowsPerPage") ?? "") ?? 200
        return pageSizeRange.contains(saved) ? saved : 200
    }

    /// The first row of the page, counted over the whole result.
    var pageStart: Int { page * rowsPerPage }
    /// Rows on this page: a full page until the result is known to end sooner.
    var pageRowCount: Int { min(rowsPerPage, max(0, rowCount - pageStart)) }
    /// Pages in all, when the total is known or estimated.
    var pageCount: Int? { knownCount.map { max(1, Int((Double($0) / Double(rowsPerPage)).rounded(.up))) } }

    /// An estimate never stops you going on: only a known end does.
    var hasNextPage: Bool {
        if let knownCount, !countIsEstimate { return pageStart + rowsPerPage < knownCount }
        if !lastPageFull { return loadedEnd > pageStart + rowsPerPage }
        return true
    }

    func showPage(_ number: Int) {
        let target = max(0, number)
        guard target != page else { return }
        page = target
        _ = recomputeNotes()
        structureRevision += 1
        onPageShown?()
    }

    func setRowsPerPage(_ size: Int) {
        guard GridModel.pageSizeRange.contains(size), size != rowsPerPage else { return }
        let first = pageStart
        rowsPerPage = size
        Defaults.set(String(size), "rowsPerPage")
        page = first / size
        _ = recomputeNotes()
        structureRevision += 1
        onPageShown?()
    }

    /// Replaces an estimate with an exact count, however long it takes (up to a minute).
    func countExactly() {
        guard let browser = workspace?.browser, !counting else { return }
        let query = self.query
        let generation = self.generation
        counting = true
        Task {
            let count = try? await browser.count(query, timeout: .seconds(60))
            guard generation == self.generation else { return }
            counting = false
            if let count {
                knownCount = count
                countIsEstimate = false
                structureRevision += 1
            }
        }
    }

    private(set) var knownCount: Int?
    private(set) var countIsEstimate = false
    private(set) var counting = false
    private(set) var loadedEnd = 0
    private(set) var lastPageFull = true
    private(set) var error: String?
    private(set) var loadingFirstPage = true

    /// Bumps when columns or the row count change: the grid reloads everything.
    private(set) var structureRevision = 0
    /// Bumps when edit or proposal marks change: the grid redraws visible rows.
    private(set) var overlayRevision = 0
    /// Where an agent is looking in this table, for the live cursor.
    private(set) var agentFocus: (client: String, column: String)?

    @ObservationIgnored private var pages: [Int: [[CellValue]]] = [:]
    @ObservationIgnored private var loading: Set<Int> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var resultColumns: [String: Int] = [:]
    @ObservationIgnored private var stagedByKey: [String: RowChange] = [:]
    @ObservationIgnored private var proposedByKey: [String: (id: String, kind: ProposalPreview.Kind, values: [String: String?])] = [:]
    /// Agent notes shown as a full-width row under the first loaded row each proposal changes,
    /// sorted by that row.
    @ObservationIgnored private(set) var notes: [(after: Int, proposal: String)] = []
    /// Called with the row range a page covers once it arrives.
    @ObservationIgnored var onRowsLoaded: (@MainActor (Range<Int>) -> Void)?
    /// A new page went on screen: the grid scrolls back to its top.
    @ObservationIgnored var onPageShown: (@MainActor () -> Void)?
    /// Rows you added to this table, not saved yet. They show above the loaded rows.
    @ObservationIgnored private(set) var inserts: [RowChange] = []
    /// A new row whose cell editor opens once the grid shows it.
    @ObservationIgnored var pendingEdit: (id: UUID, column: String)?
    /// Rows (data indices) to select once they load, as after following a foreign key.
    @ObservationIgnored var selectRows: IndexSet?
    /// Selected display rows, as the grid reports them.
    var selection = IndexSet()
    /// Set when this table was opened by following a foreign key.
    var cameFrom: BackLink?
    var viewTab: TableTab = .data
    /// The column or index the Structure tab's side panel shows.
    var structureSelection: StructureItem?
    /// The SQL tab's text, results and file; made the first time the tab opens.
    @ObservationIgnored private(set) lazy var sql = SQLDocument(grid: self)
    /// The copy or export the Export panel started.
    let exportJob = ExportJob()

    static let pageSize = 200

    init(table: TableRef, workspace: WorkspaceModel) {
        self.table = table
        self.workspace = workspace
    }

    var dialect: SQLDialect { workspace?.dialect ?? .sqlite }
    var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
    var isEditable: Bool { description?.table.kind == .table && !primaryKey.isEmpty }
    var canInsert: Bool { description?.table.kind == .table }
    var visibleColumns: [GridColumn] { columns.filter { !$0.hidden } }

    var query: TableQuery {
        TableQuery(
            table: table, dialect: dialect, filter: filter, sort: sort, primaryKey: primaryKey,
            search: search, searchColumns: columns.filter { $0.category != .binary }.map(\.name)
        )
    }

    /// Every row of the table in this view's sort, without filters or search.
    var wholeTableQuery: TableQuery {
        TableQuery(table: table, dialect: dialect, sort: sort, primaryKey: primaryKey)
    }

    /// Rows the grid shows: the exact count when known, otherwise what is loaded plus one page.
    var rowCount: Int {
        if let knownCount, !countIsEstimate { return knownCount }
        if !lastPageFull { return loadedEnd }
        return max(loadedEnd + (loadedEnd == 0 && loadingFirstPage ? 0 : Self.pageSize), knownCount ?? 0)
    }

    var rowCountLabel: String {
        if let knownCount {
            let total = knownCount.grouped
            if countIsEstimate { return String(localized: "≈\(total) rows") }
            if filter.isEmpty && search.isEmpty { return String(localized: "\(total) rows") }
            let estimate = workspace?.estimates[table].map { $0.grouped } ?? "…"
            return String(localized: "\(total) of \(estimate) rows")
        }
        if counting { return String(localized: "counting…") }
        return lastPageFull ? String(localized: "\(loadedEnd.grouped)+ rows") : String(localized: "\(loadedEnd.grouped) rows")
    }

    // MARK: Loading

    func start() async {
        guard let workspace else { return }
        description = await workspace.describe(table)
        if let description {
            columns = makeColumns(description, engine: workspace.profile.engine)
            applyLayout(layoutKey.flatMap(Defaults.layout))
            layoutReady = true
        }
        overlaysChanged()
        reload()
    }

    /// The table's columns or indexes changed: read its structure again and rebuild the grid.
    /// Filters and sorts on columns that are gone are dropped.
    func structureChanged() async {
        guard let workspace else { return }
        description = await workspace.describe(table)
        guard let description else { return }
        let names = Set(description.columns.map(\.name))
        layoutReady = false
        columns = makeColumns(description, engine: workspace.profile.engine)
        applyLayout(layoutKey.flatMap(Defaults.layout))
        layoutReady = true
        if !filter.filteredColumns.isSubset(of: names) { filter = TableFilter() }
        switch structureSelection {
        case .column(let name)? where !names.contains(name): structureSelection = nil
        case .index(let name)? where !description.indexes.contains(where: { $0.name == name }): structureSelection = nil
        case .newColumn?, .newIndex?: structureSelection = nil
        default: break
        }
        overlaysChanged()
        reload()
    }

    private func makeColumns(_ description: TableDescription, engine: DatabaseEngine) -> [GridColumn] {
        let foreign = Dictionary(description.foreignKeys.map { ($0.column, $0) }, uniquingKeysWith: { first, _ in first })
        let singleKey = description.columns.filter(\.primaryKey).count == 1
        return description.columns.map { info in
            let category = ColumnCategory(typeName: info.type)
            return GridColumn(
                name: info.name,
                type: Self.shortType(info.type),
                category: category,
                isPrimaryKey: info.primaryKey,
                foreignTable: foreign[info.name]?.referencedTable,
                nullable: info.nullable,
                width: Self.width(name: info.name, category: category, foreign: foreign[info.name]?.referencedTable),
                foreignKey: foreign[info.name],
                defaultValue: info.defaultValue,
                autoValue: Self.isAutoValue(info, singleKey: singleKey, engine: engine)
            )
        }
    }

    // MARK: Layout

    private var layoutKey: String? {
        workspace.map { Defaults.layoutKey($0.profile.id, table) }
    }

    /// The columns as the table defines them, for telling a changed layout from the default.
    private var tableColumnNames: [String] {
        description?.columns.map(\.name) ?? columns.map(\.name)
    }

    var defaultSort: [SortKey] {
        (workspace?.app?.defaultOrder ?? .oldestFirst).sort(primaryKey: primaryKey)
    }

    /// The layout as it is now: the sort only if the person picked it, widths only where changed.
    var currentLayout: TableLayout {
        var widths: [String: Double] = [:]
        for column in columns where abs(column.width - Self.width(name: column.name, category: column.category, foreign: column.foreignTable)) > 0.5 {
            widths[column.name] = column.width.rounded()
        }
        return TableLayout(sort: sortIsDefault ? nil : sort, order: columns.map(\.name), hidden: columns.filter(\.hidden).map(\.name), widths: widths)
    }

    var hasCustomLayout: Bool {
        _ = sort
        return !currentLayout.isDefault(columns: tableColumnNames)
    }

    /// Puts a remembered layout, or the defaults, on freshly described columns.
    private func applyLayout(_ layout: TableLayout?) {
        let names = columns.map(\.name)
        if let layout {
            let byName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let hidden = layout.hiddenColumns(names)
            columns = layout.ordered(names).compactMap { name in
                guard var column = byName[name] else { return nil }
                column.hidden = hidden.contains(name)
                if let width = layout.widths[name] { column.width = min(max(width, 48), 1_200) }
                return column
            }
        }
        if let keys = layout?.sortKeys(names) {
            setSort(keys, isDefault: false, reload: false)
        } else {
            setSort(defaultSort, isDefault: true, reload: false)
        }
    }

    private func setSort(_ keys: [SortKey], isDefault: Bool, reload: Bool) {
        settingSort = true
        holdReload = !reload
        sort = keys
        settingSort = false
        holdReload = false
        sortIsDefault = isDefault
    }

    /// Remembers the layout shortly after it changes; a layout like the default is forgotten.
    private func layoutChanged() {
        guard layoutReady, let key = layoutKey else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let layout = currentLayout
            Defaults.setLayout(layout.isDefault(columns: tableColumnNames) ? nil : layout, key)
        }
    }

    /// Every column back, in the table's order and default widths, sorted by the default order.
    func resetLayout() {
        guard let description, let workspace else { return }
        layoutReady = false
        columns = makeColumns(description, engine: workspace.profile.engine)
        setSort(defaultSort, isDefault: true, reload: true)
        layoutReady = true
        saveTask?.cancel()
        if let layoutKey { Defaults.setLayout(nil, layoutKey) }
    }

    /// The default order changed in Settings: tables still on it follow.
    func defaultOrderChanged() {
        guard sortIsDefault, layoutReady else { return }
        setSort(defaultSort, isDefault: true, reload: true)
        layoutChanged()
    }

    func reload() {
        generation += 1
        notes = []
        pages.removeAll()
        loading.removeAll()
        loadedEnd = 0
        lastPageFull = true
        loadingFirstPage = true
        knownCount = nil
        countIsEstimate = false
        error = nil
        structureRevision += 1
        load(page: 0)
        recount()
    }

    private func recount() {
        guard let browser = workspace?.browser else { return }
        let query = self.query
        let generation = self.generation
        let estimate = filter.isEmpty ? workspace?.estimates[table] : nil
        counting = true
        Task {
            var count: Int?
            var isEstimate = false
            if let estimate, workspace?.profile.engine == .postgres, estimate > 500_000 {
                count = estimate
                isEstimate = true
            } else {
                count = try? await browser.count(query, timeout: .seconds(5))
                if count == nil, let estimate {
                    count = estimate
                    isEstimate = true
                }
            }
            guard generation == self.generation else { return }
            counting = false
            knownCount = count
            countIsEstimate = isEstimate
            structureRevision += 1
        }
    }

    func row(_ index: Int) -> [CellValue]? {
        let page = index / Self.pageSize
        guard let rows = pages[page] else {
            load(page: page)
            return nil
        }
        let offset = index - page * Self.pageSize
        return offset < rows.count ? rows[offset] : nil
    }

    /// A row that is already loaded; never starts loading.
    func loadedRow(_ index: Int) -> [CellValue]? {
        let page = index / Self.pageSize
        guard let rows = pages[page] else { return nil }
        let offset = index - page * Self.pageSize
        return offset < rows.count ? rows[offset] : nil
    }

    func value(row: [CellValue], column: String) -> CellValue? {
        resultColumns[column].flatMap { $0 < row.count ? row[$0] : nil }
    }

    private func load(page: Int) {
        guard !loading.contains(page), pages[page] == nil, let browser = workspace?.browser else { return }
        loading.insert(page)
        let query = self.query
        let generation = self.generation
        Task {
            do {
                let result = try await browser.page(query, offset: page * Self.pageSize, limit: Self.pageSize)
                guard generation == self.generation else { return }
                loading.remove(page)
                if resultColumns.isEmpty || resultColumns.count != result.columns.count {
                    resultColumns = Dictionary(result.columns.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
                    if columns.isEmpty {
                        columns = result.columns.map {
                            let category = ColumnCategory(typeName: $0.typeName ?? "")
                            return GridColumn(name: $0.name, type: $0.typeName ?? "", category: category, isPrimaryKey: false, nullable: true, width: Self.width(name: $0.name, category: category, foreign: nil))
                        }
                        structureRevision += 1
                    }
                }
                pages[page] = result.rows
                let start = page * Self.pageSize
                let end = start + result.rows.count
                let grew = end > loadedEnd
                if grew { loadedEnd = end }
                if result.rows.count < Self.pageSize {
                    lastPageFull = false
                    if knownCount == nil || countIsEstimate { knownCount = end; countIsEstimate = false }
                }
                let wasFirst = loadingFirstPage
                loadingFirstPage = false
                let notesMoved = recomputeNotes()
                if grew && (knownCount == nil || countIsEstimate) || wasFirst || notesMoved {
                    structureRevision += 1
                } else {
                    onRowsLoaded?(start..<max(end, start + 1))
                }
            } catch {
                guard generation == self.generation else { return }
                loading.remove(page)
                loadingFirstPage = false
                self.error = "\(error)"
                lastPageFull = false
                structureRevision += 1
            }
        }
    }

    func valueCounts(column: String, excluding condition: UUID?, search: String?) async throws -> [ValueCount] {
        guard let browser = workspace?.browser else { return [] }
        return try await browser.valueCounts(query, column: column, excluding: condition, search: search, limit: 50)
    }

    // MARK: Edits and proposals

    func key(of row: [CellValue]) -> [KeyValue]? {
        let keys = primaryKey
        guard !keys.isEmpty else { return nil }
        var parts: [KeyValue] = []
        for name in keys {
            guard let value = value(row: row, column: name) else { return nil }
            parts.append(KeyValue(column: name, value: value))
        }
        return parts
    }

    static func keyString(_ texts: [String?]) -> String {
        texts.map { $0 ?? "\u{0}" }.joined(separator: "\u{1F}")
    }

    private func keyString(of row: [CellValue]) -> String? {
        key(of: row).map { Self.keyString($0.map { $0.value.isNull ? nil : $0.value.displayText }) }
    }

    /// Re-reads staged edits, proposals and agent focus for this table.
    func overlaysChanged() {
        guard let workspace else { return }
        stagedByKey = [:]
        let added = workspace.staged.filter { $0.table == table && $0.isInsert }
        let insertsMoved = added.map(\.id) != inserts.map(\.id)
        inserts = added
        for change in workspace.staged where change.table == table && change.mergesByRow {
            stagedByKey[Self.keyString(change.key.map { $0.value.isNull ? nil : $0.value.displayText })] = change
        }
        proposedByKey = [:]
        let keys = primaryKey
        for proposal in workspace.pending {
            guard let preview = proposal.preview, preview.table.lowercased() == table.name.lowercased(),
                  preview.schema == nil || table.schema == nil || preview.schema == table.schema,
                  preview.kind != .insert, !keys.isEmpty else { continue }
            let indices = keys.compactMap { preview.columns.firstIndex(of: $0) }
            guard indices.count == keys.count else { continue }
            for row in preview.rows {
                let key = Self.keyString(indices.map { row[$0] })
                var values: [String: String?] = [:]
                for (index, name) in preview.columns.enumerated() where !keys.contains(name) {
                    values[name] = row[index]
                }
                proposedByKey[key] = (proposal.id, preview.kind, values)
            }
        }
        agentFocus = Self.focus(in: workspace, table: table, columns: columns.map(\.name))
        if recomputeNotes() || insertsMoved { structureRevision += 1 }
        overlayRevision += 1
    }

    // MARK: Display rows (data rows with agent notes between them)

    enum DisplayRow: Equatable {
        case data(Int)
        case note(String)
        /// A row you added, by its staged change.
        case new(UUID)
    }

    /// Agent notes under rows of this page.
    private var pageNotes: [(after: Int, proposal: String)] {
        let range = pageStart..<(pageStart + pageRowCount)
        return notes.filter { range.contains($0.after) }
    }

    var displayCount: Int { inserts.count + pageRowCount + pageNotes.count }

    /// Data rows are numbered over the whole result; the grid shows this page's.
    func displayRow(_ index: Int) -> DisplayRow {
        if index < inserts.count { return .new(inserts[index].id) }
        let index = index - inserts.count
        for (offset, note) in pageNotes.enumerated() {
            let noteIndex = note.after - pageStart + offset + 1
            if index == noteIndex { return .note(note.proposal) }
            if index < noteIndex { return .data(pageStart + index - offset) }
        }
        return .data(pageStart + index - pageNotes.count)
    }

    func displayIndex(ofData row: Int) -> Int {
        inserts.count + (row - pageStart) + pageNotes.prefix { $0.after < row }.count
    }

    func displayIndex(ofInsert id: UUID) -> Int? {
        inserts.firstIndex { $0.id == id }
    }

    func insert(_ id: UUID) -> RowChange? {
        inserts.first { $0.id == id }
    }

    /// The value you gave a column of a new row; `nil` when you left it to the database.
    func insertValue(_ id: UUID, column: String) -> CellValue? {
        guard case .insert(let values)? = insert(id)?.kind else { return nil }
        return values.first { $0.column == column }?.value
    }

    /// What an empty cell of a new row gets: its default, NULL, or nothing (it must be filled in).
    func placeholder(for column: GridColumn) -> String {
        if column.autoValue || column.defaultValue != nil { return String(localized: "default") }
        return column.nullable ? "NULL" : String(localized: "required")
    }

    /// The loaded rows behind the selection, in order; new rows are left out.
    var selectedRows: [[CellValue]] {
        selection.compactMap { data(atDisplay: $0) }
    }

    /// The loaded row at a display index; `nil` for note rows and rows still loading.
    func data(atDisplay index: Int) -> [CellValue]? {
        if case .data(let row) = displayRow(index) { return self.row(row) }
        return nil
    }

    func proposal(_ id: String) -> Proposal? {
        workspace?.pending.first { $0.id == id }
    }

    /// Finds the first loaded row of each proposal. Returns whether the notes moved.
    private func recomputeNotes() -> Bool {
        var first: [String: Int] = [:]
        if !proposedByKey.isEmpty {
            for page in pages.keys.sorted() {
                guard let rows = pages[page] else { continue }
                for (offset, row) in rows.enumerated() {
                    guard let key = keyString(of: row), let proposal = proposedByKey[key]?.id, first[proposal] == nil else { continue }
                    first[proposal] = page * Self.pageSize + offset
                }
            }
        }
        let updated = first.map { (after: $0.value, proposal: $0.key) }.sorted { $0.after < $1.after }
        let changed = updated.map(\.after) != notes.map(\.after) || updated.map(\.proposal) != notes.map(\.proposal)
        notes = updated
        return changed
    }

    func marks(row: [CellValue]) -> RowMarks {
        guard let key = keyString(of: row) else { return RowMarks() }
        var marks = RowMarks()
        if let change = stagedByKey[key] {
            if case .delete = change.kind { marks.deletedByYou = true } else { marks.editedByYou = true }
        }
        if let proposed = proposedByKey[key] {
            marks.proposal = proposed.id
            marks.deletedByAgent = proposed.kind == .delete
        }
        return marks
    }

    func mark(row: [CellValue], column: String) -> CellMark {
        guard let key = keyString(of: row) else { return .none }
        let current = value(row: row, column: column) ?? .null
        if let change = stagedByKey[key], case .update(let columns) = change.kind,
           let edit = columns.first(where: { $0.column == column }) {
            return .edited(was: edit.old, now: edit.new)
        }
        if let proposed = proposedByKey[key], proposed.kind == .update, let new = proposed.values[column] {
            let currentText = current.isNull ? nil : current.displayText
            if new != currentText { return .proposed(was: current, now: new) }
        }
        return .none
    }

    /// Stages a new value for one cell of a loaded row.
    func stageEdit(row: [CellValue], column: String, to new: CellValue) {
        guard let workspace, isEditable, let key = key(of: row), let info = columns.first(where: { $0.name == column }) else { return }
        let original: CellValue
        if let existing = stagedByKey[keyString(of: row) ?? ""], case .update(let changes) = existing.kind,
           let change = changes.first(where: { $0.column == column }) {
            original = change.old
        } else {
            original = value(row: row, column: column) ?? .null
        }
        let change = RowChange(table: table, key: key, kind: .update([ColumnChange(column: column, category: info.category, old: original, new: new)]))
        workspace.recordingUndo(new.isNull ? "Set to NULL" : "Edit") { workspace.stage(change) }
    }

    func stageDelete(rows: [[CellValue]]) {
        guard let workspace, isEditable else { return }
        workspace.recordingUndo(rows.count == 1 ? "Delete Row" : "Delete Rows") {
            for row in rows {
                guard let key = key(of: row) else { continue }
                let change = RowChange(table: table, key: key, kind: .delete)
                workspace.stage(change, note: ChangeNote(detail: summary(of: row)))
            }
        }
    }

    /// A few of the row's values, for the list of changes: "14 · delivered · 18.40 · EUR".
    func summary(of row: [CellValue]) -> String {
        visibleColumns.filter { !$0.isPrimaryKey }.prefix(4).map { column in
            GridStyle.display(value(row: row, column: column.name) ?? .null, scale: column.scale)
        }.joined(separator: " · ")
    }

    // MARK: New rows

    /// Adds an empty row on top of the grid and opens its first cell for typing.
    @discardableResult
    func addRow() -> UUID? {
        guard let workspace, canInsert else { return nil }
        let change = RowChange(table: table, key: [], kind: .insert([]))
        workspace.recordingUndo("New Row") { workspace.stage(change) }
        let first = visibleColumns.first { !$0.autoValue } ?? visibleColumns.first
        if let first { pendingEdit = (change.id, first.name) }
        return change.id
    }

    /// New rows with the values of these rows, keys and generated values left to the database.
    func duplicate(_ rows: [[CellValue]]) {
        guard let workspace, canInsert else { return }
        workspace.recordingUndo(rows.count == 1 ? "Duplicate Row" : "Duplicate Rows") {
            for row in rows {
                let values = columns.compactMap { column -> KeyValue? in
                    guard !column.isPrimaryKey, !column.autoValue, let value = value(row: row, column: column.name), !value.isNull else { return nil }
                    return KeyValue(column: column.name, value: value)
                }
                let source = key(of: row).map { $0.map(\.value.displayText).joined(separator: " · ") }
                workspace.stage(RowChange(table: table, key: [], kind: .insert(values)), note: ChangeNote(title: source.map { String(localized: "Copy of \($0)") }))
            }
        }
    }

    /// Rows as text in a format, visible columns in grid order.
    func text(for rows: [[CellValue]], format: ExportFormat) -> String {
        let columns = exportColumns
        let projected = rows.map { row in columns.map { value(row: row, column: $0.name) ?? .null } }
        return RowWriter.text(format, columns: columns, rows: projected, table: table, dialect: dialect)
    }

    var exportColumns: [ExportColumn] {
        visibleColumns.map { ExportColumn(name: $0.name, category: $0.category, scale: $0.scale) }
    }

    /// The row's key as text, "84209".
    func keyText(of row: [CellValue]) -> String {
        key(of: row).map { $0.map(\.value.displayText).joined(separator: " · ") } ?? ""
    }

    /// Opens the row a foreign key cell points to.
    func follow(column name: String, in row: [CellValue]) {
        guard let workspace, let key = columns.first(where: { $0.name == name })?.foreignKey,
              let value = value(row: row, column: name), !value.isNull else { return }
        let from = table
        let fromKey = keyText(of: row)
        Task {
            guard let column = await workspace.referencedColumn(key) else { return }
            workspace.follow(to: workspace.referencedTable(key), column: column, value: value, from: from, key: fromKey)
        }
    }

    /// Sets (or with `nil` clears) a value of a new row.
    func setInsertValue(_ id: UUID, column: String, to value: CellValue?) {
        workspace?.updateInsert(id, column: column, value: value, order: columns.map(\.name))
    }

    func stagedChange(row: [CellValue]) -> RowChange? {
        keyString(of: row).flatMap { stagedByKey[$0] }
    }

    /// Turns typed text into a value for a column: booleans become booleans, the rest stays text
    /// and the database converts it.
    func parse(_ text: String, for column: GridColumn) -> CellValue {
        if column.category == .boolean {
            switch text.lowercased() {
            case "true", "t", "yes", "1": return .bool(true)
            case "false", "f", "no", "0": return .bool(false)
            default: break
            }
        }
        if text.isEmpty && column.category != .text && column.nullable { return .null }
        return .text(text)
    }

    // MARK: Agent focus

    /// The column of this table an agent touched last, judged from the newest agent event on the
    /// connection that mentions the table.
    static func focus(in workspace: WorkspaceModel, table: TableRef, columns: [String]) -> (client: String, column: String)? {
        guard let item = workspace.events.last(where: { $0.event.client != "you" }) else { return nil }
        let event = item.event
        guard Date.now.timeIntervalSince(event.at) < ActivityFeed.presenceWindow else { return nil }
        let sql = event.sql.lowercased()
        guard SQLText.mentions(sql, table.name.lowercased()) else { return nil }
        let column = SQLText.lastMentioned(in: sql, of: columns) ?? columns.first
        return column.map { (event.client, $0) }
    }

    // MARK: Layout

    /// Whether the database fills the column in by itself: a sequence or identity default, or
    /// SQLite's `INTEGER PRIMARY KEY`, which is the row id.
    static func isAutoValue(_ info: ColumnInfo, singleKey: Bool, engine: DatabaseEngine) -> Bool {
        if let value = info.defaultValue?.lowercased(),
           value.contains("nextval(") || value.contains("identity") || value.contains("gen_random_uuid") || value.contains("uuid_generate") {
            return true
        }
        return engine == .sqlite && info.primaryKey && singleKey && info.type.uppercased() == "INTEGER"
    }

    static func shortType(_ type: String) -> String {
        let lowered = type.lowercased()
        let map = ["bigint": "int8", "integer": "int4", "smallint": "int2", "timestamp with time zone": "timestamptz",
                   "timestamp without time zone": "timestamp", "character varying": "varchar", "double precision": "float8", "boolean": "bool"]
        for (long, short) in map where lowered.hasPrefix(long) {
            return short + lowered.dropFirst(long.count)
        }
        return lowered
    }

    static func width(name: String, category: ColumnCategory, foreign: String?) -> Double {
        let base: Double = switch category {
        case .integer: 90
        case .decimal: 110
        case .dateTime: 130
        case .date: 110
        case .boolean: 80
        case .text, .other, .json: 170
        case .binary: 140
        }
        let header = Double(name.count) * 7.4 + 34 + (foreign.map { Double($0.count) * 6.8 + 22 } ?? 0)
        return min(max(base, header), 320)
    }
}

extension CellValue {
    var isNumber: Bool {
        switch self {
        case .integer, .real: true
        default: false
        }
    }
}

/// Small text helpers for reading agent SQL.
enum SQLText {
    static func mentions(_ sql: String, _ name: String) -> Bool {
        lastIndex(of: name, in: sql) != nil
    }

    /// The column whose name appears last in the SQL, as a whole word.
    static func lastMentioned(in sql: String, of columns: [String]) -> String? {
        columns
            .compactMap { column in lastIndex(of: column.lowercased(), in: sql).map { (column, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    static func lastIndex(of word: String, in text: String) -> String.Index? {
        guard !word.isEmpty else { return nil }
        var found: String.Index?
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: word, range: searchRange) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isWordCharacter(before) && !isWordCharacter(after) { found = range.lowerBound }
            searchRange = range.upperBound..<text.endIndex
        }
        return found
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
