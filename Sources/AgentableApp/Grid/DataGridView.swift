import AppKit
import SwiftUI
import AgentableCore

/// The table grid: an AppKit `NSTableView` that only builds views for visible rows and asks the
/// model for pages as they scroll into view.
struct DataGridView: NSViewRepresentable {
    let model: GridModel
    var onOpenProposal: (String) -> Void = { _ in }
    /// Starts a filter on a column from its header menu.
    var onFilterColumn: (String) -> Void = { _ in }
    var onFilter: (FilterCondition) -> Void = { _ in }

    func makeCoordinator() -> GridCoordinator {
        GridCoordinator(model: model)
    }

    func makeNSView(context: Context) -> GridContainerView {
        let container = GridContainerView()
        context.coordinator.attach(container)
        return container
    }

    func updateNSView(_ container: GridContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpenProposal = onOpenProposal
        coordinator.onFilter = onFilter
        coordinator.onFilterColumn = onFilterColumn
        // Reading these registers them with Observation, so changes call back here.
        coordinator.sync(
            structure: model.structureRevision,
            overlay: model.overlayRevision,
            columns: model.visibleColumns,
            filtered: model.filter.filteredColumns,
            sort: model.sort,
            focus: model.agentFocus.map { "\($0.client)\u{1F}\($0.column)" }
        )
    }

    static func dismantleNSView(_ container: GridContainerView, coordinator: GridCoordinator) {
        coordinator.model.onRowsLoaded = nil
        coordinator.model.onPageShown = nil
    }
}

/// Holds the scroll view and the agent cursor above it.
final class GridContainerView: NSView {
    let scrollView = NSScrollView()
    let tableView = GridTableView()
    let cursor = AgentCursorView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .tmWindow
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        addSubview(cursor)
        cursor.isHidden = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
}

final class GridTableView: NSTableView {
    weak var coordinator: GridCoordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    /// A table view keeps clicks on its cells for selection unless they land on a control. The
    /// foreign key arrow and the proposal tick are drawn, not controls, so let their clicks through.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let event, let cell = responder as? GridCellView, cell.takesClick(event) { return true }
        if let gutter = responder as? GutterCellView, gutter.marks.proposal != nil { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    /// Clicks on the foreign key arrow or the proposal tick act on them; the rest select rows.
    /// The table often keeps clicks on its cells, so it checks for these itself.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        if row >= 0, column >= 0 {
            let view = view(atColumn: column, row: row, makeIfNecessary: false)
            if let cell = view as? GridCellView, cell.takesClick(event) {
                cell.onFollow?()
                return
            }
            if let gutter = view as? GutterCellView, let proposal = gutter.marks.proposal {
                gutter.onOpenProposal?(proposal)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, selectedRow >= 0, let coordinator { // Return edits the first editable cell
            coordinator.beginEditing(row: selectedRow, column: coordinator.firstEditableColumn)
            return
        }
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control]).isEmpty, let coordinator { // Space shows the row
            coordinator.toggleRowPanel()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class GridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let model: GridModel
    weak var container: GridContainerView?
    var onOpenProposal: (String) -> Void = { _ in }
    var onFilter: (FilterCondition) -> Void = { _ in }
    var onFilterColumn: (String) -> Void = { _ in }
    private let headerMenu = NSMenu()

    private var structure = -1
    private var overlay = -1
    private var columnSignature: [String] = []
    private var editor: NSTextField?
    private var editing: (row: Int, column: String)?

    static let gutter = NSUserInterfaceItemIdentifier("gutter")
    static let cell = NSUserInterfaceItemIdentifier("cell")

    init(model: GridModel) {
        self.model = model
    }

    var tableView: GridTableView? { container?.tableView }

    func attach(_ container: GridContainerView) {
        self.container = container
        let table = container.tableView
        table.coordinator = self
        table.dataSource = self
        table.delegate = self
        table.rowHeight = GridStyle.rowHeight
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.backgroundColor = .tmWindow
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnSelection = false
        table.style = .plain
        table.floatsGroupRows = false
        table.selectionHighlightStyle = .regular
        table.headerView = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: GridStyle.headerHeight))
        table.cornerView = nil
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        model.onRowsLoaded = { [weak self] range in self?.rowsLoaded(range) }
        model.onPageShown = { [weak self] in
            DispatchQueue.main.async { self?.tableView?.scrollRowToVisible(0) }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: container.scrollView.contentView
        )
        container.scrollView.contentView.postsBoundsChangedNotifications = true
    }

    func sync(structure: Int, overlay: Int, columns: [GridColumn], filtered: Set<String>, sort: [SortKey], focus: String?) {
        guard let table = tableView else { return }
        let signature = columns.map(\.name)
        if signature != columnSignature {
            rebuildColumns(columns)
        }
        updateHeaders(filtered: filtered, sort: sort)
        if structure != self.structure {
            self.structure = structure
            self.overlay = overlay
            cancelEditing()
            table.reloadData()
            // Selecting or editing changes observed state, so it waits until this update is done.
            DispatchQueue.main.async { [weak self] in self?.afterReload() }
        } else if overlay != self.overlay {
            self.overlay = overlay
            reloadVisible()
        }
        if model.selectRows != nil || model.pendingEdit != nil {
            DispatchQueue.main.async { [weak self] in self?.afterReload() }
        }
        placeCursor()
    }

    /// Opens the editor on a row just added, or selects the first row after following a key.
    private func afterReload() {
        guard let table = tableView else { return }
        if let pending = model.pendingEdit, let index = model.displayIndex(ofInsert: pending.id) {
            model.pendingEdit = nil
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            beginEditing(row: index, column: pending.column)
        } else if let rows = model.selectRows, model.description != nil, !model.loadingFirstPage, model.rowCount > 0 {
            // Waits for the table's description: loading it reloads the rows, which drops a selection.
            model.selectRows = nil
            let onPage = model.pageStart..<(model.pageStart + model.pageRowCount)
            let display = IndexSet(rows.filter { onPage.contains($0) }.map { model.displayIndex(ofData: $0) })
            table.selectRowIndexes(display, byExtendingSelection: false)
            if let first = display.first { table.scrollRowToVisible(first) }
        }
    }

    func toggleRowPanel() {
        model.workspace?.showRow.toggle()
    }

    private func rebuildColumns(_ columns: [GridColumn]) {
        guard let table = tableView else { return }
        columnSignature = columns.map(\.name)
        for column in table.tableColumns { table.removeTableColumn(column) }
        let gutter = NSTableColumn(identifier: Self.gutter)
        gutter.width = GridStyle.gutterWidth
        gutter.minWidth = GridStyle.gutterWidth
        gutter.maxWidth = GridStyle.gutterWidth
        gutter.resizingMask = []
        gutter.headerCell = GridHeaderCell(textCell: "")
        table.addTableColumn(gutter)
        for info in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(info.name))
            column.width = info.width
            column.minWidth = 48
            column.maxWidth = 1_200
            column.resizingMask = .userResizingMask
            let header = GridHeaderCell(textCell: info.name)
            header.name = info.name
            header.foreignTable = info.foreignTable
            header.numeric = info.alignsRight
            column.headerCell = header
            var tip = "\(info.name) · \(info.type)"
            if info.isPrimaryKey { tip += " · " + String(localized: "primary key") }
            if let foreign = info.foreignTable { tip += " · " + String(localized: "references \(foreign)") }
            column.headerToolTip = tip
            table.addTableColumn(column)
        }
    }

    private func updateHeaders(filtered: Set<String>, sort: [SortKey]) {
        guard let table = tableView else { return }
        let focusColumn = model.agentFocus?.column
        for column in table.tableColumns {
            guard let header = column.headerCell as? GridHeaderCell, column.identifier != Self.gutter else { continue }
            let name = column.identifier.rawValue
            header.filtered = filtered.contains(name)
            header.agent = name == focusColumn
            header.ascending = sort.first(where: { $0.column == name })?.ascending
            header.sortRank = sort.count > 1 ? sort.firstIndex(where: { $0.column == name }).map { $0 + 1 } : nil
        }
        table.headerView?.needsDisplay = true
    }

    private func rowsLoaded(_ range: Range<Int>) {
        guard let table = tableView else { return }
        let visible = table.rows(in: table.visibleRect)
        let lower = max(model.displayIndex(ofData: range.lowerBound), visible.location)
        let upper = min(model.displayIndex(ofData: max(range.lowerBound, range.upperBound - 1)) + 1, visible.location + visible.length)
        guard lower < upper else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: lower..<upper), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        for row in lower..<upper {
            if let view = table.rowView(atRow: row, makeIfNecessary: false) as? GridRowView {
                configure(view, row: row)
            }
        }
    }

    private func reloadVisible() {
        guard let table = tableView else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        let rows = IndexSet(integersIn: visible.location..<(visible.location + visible.length))
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        for row in rows {
            if let view = table.rowView(atRow: row, makeIfNecessary: false) as? GridRowView {
                configure(view, row: row)
            }
        }
    }

    @objc private func boundsChanged() {
        placeCursor()
    }

    /// Puts the agent cursor on the header of the column the agent touched last.
    private func placeCursor() {
        guard let container, let table = tableView, let header = table.headerView else { return }
        guard let focus = model.agentFocus, let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == focus.column }) else {
            container.cursor.isHidden = true
            return
        }
        let rect = header.headerRect(ofColumn: index)
        let inContainer = header.convert(rect, to: container)
        let visible = container.scrollView.contentView.convert(container.scrollView.contentView.bounds, to: container)
        container.cursor.name = focus.client
        let size = container.cursor.intrinsicContentSize
        let origin = NSPoint(x: inContainer.minX + 2, y: inContainer.maxY - 11)
        container.cursor.frame = NSRect(origin: origin, size: size)
        container.cursor.isHidden = origin.x < visible.minX - 4 || origin.x > visible.maxX - 12
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        model.displayCount
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .note = model.displayRow(row) { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .note = model.displayRow(row) { return 40 }
        return GridStyle.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .note = model.displayRow(row) { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .note(let id) = model.displayRow(row) {
            guard tableColumn == nil, let proposal = model.proposal(id) else { return nil }
            // The row is as wide as all columns; keep the note within what is on screen.
            let visible = container?.scrollView.contentView.bounds.width ?? 800
            return NSHostingView(rootView: AgentNoteRow(proposal: proposal, width: visible) { [weak self] in self?.onOpenProposal(id) })
        }
        guard let tableColumn else { return nil }
        let values = model.data(atDisplay: row)
        let newRow: UUID? = if case .new(let id) = model.displayRow(row) { id } else { nil }
        if tableColumn.identifier == Self.gutter {
            let view = tableView.makeView(withIdentifier: Self.gutter, owner: nil) as? GutterCellView ?? {
                let view = GutterCellView()
                view.identifier = Self.gutter
                return view
            }()
            var marks = values.map(model.marks(row:)) ?? RowMarks()
            marks.isNew = newRow != nil
            view.configure(marks)
            view.onOpenProposal = { [weak self] id in self?.onOpenProposal(id) }
            return view
        }
        let view = tableView.makeView(withIdentifier: Self.cell, owner: nil) as? GridCellView ?? {
            let view = GridCellView()
            view.identifier = Self.cell
            return view
        }()
        let name = tableColumn.identifier.rawValue
        let info = model.columns.first { $0.name == name }
        let numeric = info?.alignsRight ?? false
        let status = info.map { $0.category == .text && ($0.name.lowercased().contains("status") || $0.name.lowercased() == "state") } ?? false
        if let newRow, let info {
            let value = model.insertValue(newRow, column: name)
            view.configure(
                value: value ?? .null, numeric: numeric, scale: info.scale, dateTime: info.category == .dateTime, status: status,
                mark: .none, struck: false, placeholder: value == nil ? model.placeholder(for: info) : nil
            )
        } else if let values {
            let marks = model.marks(row: values)
            let value = model.value(row: values, column: name) ?? .null
            view.configure(
                value: value,
                numeric: numeric,
                scale: info?.scale,
                dateTime: info?.category == .dateTime,
                status: status,
                mark: model.mark(row: values, column: name),
                struck: marks.deletedByYou || marks.deletedByAgent,
                link: info?.foreignKey != nil && !value.isNull && tableView.isRowSelected(row)
            )
            view.onFollow = { [weak self] in self?.model.follow(column: name, in: values) }
        } else {
            view.configure(value: .text(""), numeric: numeric, mark: .none, struck: false)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = GridRowView()
        configure(view, row: row)
        return view
    }

    private func configure(_ view: GridRowView, row: Int) {
        var marks = model.data(atDisplay: row).map(model.marks(row:)) ?? RowMarks()
        switch model.displayRow(row) {
        case .note(let id): marks.proposal = id
        case .new: marks.isNew = true
        case .data: break
        }
        if marks != view.marks {
            view.marks = marks
            view.needsDisplay = true
        }
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }

    /// Tells the model what is selected, and moves the foreign key arrows to the selected rows.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = tableView else { return }
        let old = model.selection
        let new = table.selectedRowIndexes
        if old != new { model.selection = new }
        let linked = IndexSet(table.tableColumns.indices.filter { index in
            model.columns.first { $0.name == table.tableColumns[index].identifier.rawValue }?.foreignKey != nil
        })
        let rows = old.symmetricDifference(new).filteredIndexSet { $0 < table.numberOfRows }
        guard !linked.isEmpty, !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: linked)
    }

    /// Click sorts A→Z, then Z→A, then not at all. Shift-click adds the column as a further sort key.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier != Self.gutter else { return }
        let name = tableColumn.identifier.rawValue
        let adding = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        var keys = adding ? model.sort : model.sort.filter { $0.column == name }
        if let index = keys.firstIndex(where: { $0.column == name }) {
            if keys[index].ascending { keys[index].ascending = false } else { keys.remove(at: index) }
        } else {
            keys.append(SortKey(column: name, ascending: true))
        }
        model.sort = keys
    }

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        columnIndex > 0 && newColumnIndex > 0
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard let table = tableView else { return }
        let order = table.tableColumns.map(\.identifier.rawValue).filter { $0 != Self.gutter.rawValue }
        var columns = model.columns
        columns.sort { (order.firstIndex(of: $0.name) ?? Int.max) < (order.firstIndex(of: $1.name) ?? Int.max) }
        columnSignature = columns.filter { !$0.hidden }.map(\.name)
        model.columns = columns
    }

    private func headerMenuItems(_ menu: NSMenu) {
        guard let table = tableView, let header = table.headerView, let window = table.window else { return }
        let point = header.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let index = header.column(at: point)
        guard index > 0, index < table.tableColumns.count else { return }
        let name = table.tableColumns[index].identifier.rawValue
        let sorted = model.sort.first { $0.column == name }
        menu.addItem(item("Sort A → Z") { [weak self] in self?.model.sort = [SortKey(column: name, ascending: true)] })
        menu.addItem(item("Sort Z → A") { [weak self] in self?.model.sort = [SortKey(column: name, ascending: false)] })
        if sorted != nil {
            menu.addItem(item("Clear sort") { [weak self] in self?.model.sort.removeAll { $0.column == name } })
        }
        menu.addItem(.separator())
        menu.addItem(item("Filter by \(name)…") { [weak self] in self?.onFilterColumn(name) })
        menu.addItem(item("Hide column") { [weak self] in
            guard let self, self.model.visibleColumns.count > 1, let at = self.model.columns.firstIndex(where: { $0.name == name }) else { return }
            self.model.columns[at].hidden = true
        })
        menu.addItem(.separator())
        menu.addItem(item("Copy column name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        })
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let index = model.columns.firstIndex(where: { $0.name == column.identifier.rawValue }) else { return }
        if model.columns[index].width != column.width {
            var columns = model.columns
            columns[index].width = column.width
            model.columns = columns
        }
        placeCursor()
    }

    // MARK: Editing

    var firstEditableColumn: String {
        model.visibleColumns.first { !$0.isPrimaryKey }?.name ?? model.visibleColumns.first?.name ?? ""
    }

    @objc private func doubleClicked() {
        guard let table = tableView, table.clickedRow >= 0, table.clickedColumn > 0 else { return }
        beginEditing(row: table.clickedRow, column: table.tableColumns[table.clickedColumn].identifier.rawValue)
    }

    func beginEditing(row: Int, column name: String) {
        guard let table = tableView, let info = model.columns.first(where: { $0.name == name }),
              let columnIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == name }) else { return }
        let current: CellValue
        var placeholder: String?
        switch model.displayRow(row) {
        case .new(let id):
            guard model.canInsert else { return }
            let given = model.insertValue(id, column: name)
            current = given ?? .null
            placeholder = given == nil ? model.placeholder(for: info) : nil
        case .data:
            guard model.isEditable, let values = model.data(atDisplay: row) else {
                if !model.isEditable { NSSound.beep() }
                return
            }
            if case .edited(_, let now) = model.mark(row: values, column: name) {
                current = now
            } else {
                current = model.value(row: values, column: name) ?? .null
            }
        case .note:
            return
        }
        cancelEditing()
        table.scrollColumnToVisible(columnIndex)
        let frame = table.frameOfCell(atColumn: columnIndex, row: row).insetBy(dx: 2, dy: 3)
        let field = NSTextField(frame: frame)
        field.cell = CenteredTextFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = GridStyle.cellFont
        field.stringValue = current.isNull ? "" : current.displayText
        field.placeholderString = placeholder ?? (current.isNull ? "NULL" : nil)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .tmWindow
        field.textColor = .tmText
        field.focusRingType = .none
        field.alignment = info.alignsRight ? .right : .left
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.tmYou.cgColor
        field.layer?.borderWidth = 1.5
        field.layer?.cornerRadius = 5
        field.delegate = self
        table.addSubview(field)
        table.window?.makeFirstResponder(field)
        editor = field
        editing = (row, name)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)),
           let editing, let at = model.visibleColumns.firstIndex(where: { $0.name == editing.column }) {
            let step = commandSelector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
            let next = at + step
            commitEditing()
            if model.visibleColumns.indices.contains(next) {
                beginEditing(row: editing.row, column: model.visibleColumns[next].name)
            }
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if editor != nil { commitEditing() }
    }

    private func commitEditing() {
        guard let editor, let editing, let info = model.columns.first(where: { $0.name == editing.column }) else {
            cancelEditing()
            return
        }
        if case .new(let id) = model.displayRow(editing.row) {
            let text = editor.stringValue
            let given = model.insertValue(id, column: editing.column)
            let unchanged = given.map { !$0.isNull && $0.displayText == text } ?? text.isEmpty
            cancelEditing()
            if !unchanged {
                model.setInsertValue(id, column: info.name, to: text.isEmpty ? nil : model.parse(text, for: info))
            }
            return
        }
        guard let values = model.data(atDisplay: editing.row) else {
            cancelEditing()
            return
        }
        let text = editor.stringValue
        let original = model.value(row: values, column: editing.column) ?? .null
        let unchanged = (original.isNull && text.isEmpty) || (!original.isNull && original.displayText == text)
        let staged: Bool = if case .edited = model.mark(row: values, column: editing.column) { true } else { false }
        if !unchanged || staged {
            model.stageEdit(row: values, column: editing.column, to: unchanged ? original : model.parse(text, for: info))
        }
        cancelEditing()
    }

    private func cancelEditing() {
        let field = editor
        editor = nil
        editing = nil
        field?.removeFromSuperview()
        if let table = tableView, field != nil { table.window?.makeFirstResponder(table) }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === headerMenu {
            headerMenuItems(menu)
            return
        }
        guard let table = tableView, table.clickedRow >= 0 else { return }
        let clicked = table.clickedRow
        let columnName = table.clickedColumn > 0 ? table.tableColumns[table.clickedColumn].identifier.rawValue : nil
        let info = columnName.flatMap { name in model.columns.first { $0.name == name } }

        if case .new(let id) = model.displayRow(clicked) {
            if let info {
                menu.addItem(item("Edit value") { [weak self] in self?.beginEditing(row: clicked, column: info.name) })
                if info.nullable {
                    menu.addItem(item("Set to NULL") { [weak self] in self?.model.setInsertValue(id, column: info.name, to: .null) })
                }
                menu.addItem(.separator())
            }
            menu.addItem(item("Remove new row") { [weak self] in self?.model.workspace?.unstage(id) })
            return
        }
        guard let values = model.data(atDisplay: clicked) else { return }
        // A right click inside the selection acts on all of it; elsewhere on the clicked row.
        let targets = table.selectedRowIndexes.contains(clicked) ? table.selectedRowIndexes : IndexSet(integer: clicked)
        let rows = targets.compactMap { model.data(atDisplay: $0) }
        let many = rows.count > 1
        let count = rows.count

        if let columnName, let info {
            let value = model.value(row: values, column: columnName) ?? .null
            let shown = value.isNull ? String(localized: "empty") : "“\(String(GridStyle.display(value).prefix(32)))”"
            menu.addItem(item("Only rows with \(shown)") { [weak self] in
                self?.onFilter(FilterCondition(column: columnName, category: info.category, op: value.isNull ? .isEmpty : .isAnyOf, values: value.isNull ? [] : [value]))
            })
            menu.addItem(item("Hide rows with \(shown)") { [weak self] in
                self?.onFilter(FilterCondition(column: columnName, category: info.category, op: value.isNull ? .isNotEmpty : .isNoneOf, values: value.isNull ? [] : [value]))
            })
            if let key = info.foreignKey, !value.isNull {
                let target = String(GridStyle.display(value).prefix(32))
                menu.addItem(item("Open \(key.referencedTable) \(target)") { [weak self] in
                    self?.model.follow(column: columnName, in: values)
                })
            }
            menu.addItem(.separator())
            menu.addItem(item("Copy value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value.displayText, forType: .string)
            })
        }
        let copy = item(many ? "Copy \(count) rows" : "Copy row") { [weak self] in self?.copy(rows) }
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        menu.addItem(copy)
        let copyAs = NSMenuItem(title: many ? String(localized: "Copy \(count) rows as") : String(localized: "Copy row as"), action: nil, keyEquivalent: "")
        let formats = NSMenu()
        for format in ExportFormat.allCases {
            formats.addItem(item(verbatim: format.title) { [weak self] in
                guard let self else { return }
                Self.setClipboard(self.model.text(for: rows, format: format))
            })
        }
        copyAs.submenu = formats
        menu.addItem(copyAs)
        menu.addItem(.separator())

        if model.isEditable, let columnName, let info, !many {
            menu.addItem(item("Edit value") { [weak self] in self?.beginEditing(row: clicked, column: columnName) })
            if info.nullable && !(model.value(row: values, column: columnName) ?? .null).isNull {
                menu.addItem(item("Set to NULL") { [weak self] in self?.model.stageEdit(row: values, column: columnName, to: .null) })
            }
        }
        if model.canInsert {
            menu.addItem(item(many ? "Duplicate \(count) rows" : "Duplicate row") { [weak self] in self?.model.duplicate(rows) })
        }
        if model.isEditable {
            if !many, let change = model.stagedChange(row: values) {
                menu.addItem(item("Undo your change to this row") { [weak self] in self?.model.workspace?.unstage(change.id) })
            } else {
                menu.addItem(item(many ? "Delete \(count) rows" : "Delete row") { [weak self] in self?.model.stageDelete(rows: rows) })
            }
        }
        menu.addItem(.separator())
        let details = item(model.workspace?.showRow == true ? "Hide row details" : "Row details") { [weak self] in
            self?.table(select: clicked)
            self?.toggleRowPanel()
        }
        details.keyEquivalent = " "
        details.keyEquivalentModifierMask = []
        menu.addItem(details)
        if let proposal = model.marks(row: values).proposal {
            menu.addItem(.separator())
            menu.addItem(item("Review the agent's change…") { [weak self] in self?.onOpenProposal(proposal) })
        }
    }

    /// Selects the row unless it is already part of the selection.
    private func table(select row: Int) {
        guard let table = tableView, !table.selectedRowIndexes.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func item(_ title: String.LocalizationValue, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        item(verbatim: String(localized: title), action)
    }

    private func item(verbatim title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        return item
    }

    /// ⌘C: the selected rows as tab-separated text with a header line.
    func copySelection() {
        guard let table = tableView else { return }
        let rows = table.selectedRowIndexes.compactMap { model.data(atDisplay: $0) }
        if !rows.isEmpty { copy(rows) }
    }

    private func copy(_ rows: [[CellValue]]) {
        let columns = model.visibleColumns.map(\.name)
        var lines = [columns.joined(separator: "\t")]
        for values in rows {
            lines.append(columns.map { GridStyle.display(model.value(row: values, column: $0) ?? .null) }.joined(separator: "\t"))
        }
        Self.setClipboard(lines.joined(separator: "\n"))
    }

    static func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A text field cell whose text sits in the vertical middle, with a little room on the sides, so
/// the cell editor lines up with the value it replaces.
final class CenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ bounds: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: bounds).insetBy(dx: 3, dy: 0)
        let height = cellSize(forBounds: bounds).height
        if height < rect.height {
            rect.origin.y += floor((rect.height - height) / 2)
            rect.size.height = height
        }
        return rect
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { centered(rect) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// Lets a menu item run a closure.
final class MenuAction: NSObject {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor @objc func run() {
        action()
    }
}

/// An agent's note under the first row it wants to change, as in the design: who, why, and a way
/// to the review.
struct AgentNoteRow: View {
    let proposal: Proposal
    let width: CGFloat
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(proposal.client).font(.ui(12.5, .semibold)).foregroundStyle(Color.tmAgentText)
            Text(proposal.reason ?? String(localized: "\(ProposalText.title(proposal)), waiting for your review."))
                .font(.ui(12.5))
                .foregroundStyle(Color.tmText2)
                .lineLimit(1)
            Button("Review", action: onReview)
                .buttonStyle(.secondary(height: 24))
                .font(.ui(12))
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
