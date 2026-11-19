import AppKit
import SwiftUI
import AgentableCore

/// The rows a query returned, read-only, drawn with the table grid's cells so both look the same.
struct ResultGridView: NSViewRepresentable {
    let result: QueryResult
    let revision: Int
    let table: TableRef
    let dialect: SQLDialect

    func makeCoordinator() -> ResultGridCoordinator {
        ResultGridCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .tmWindow
        let tableView = ResultTableView()
        tableView.coordinator = context.coordinator
        tableView.rowHeight = 32
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.backgroundColor = .tmWindow
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.style = .plain
        tableView.headerView = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: GridStyle.headerHeight))
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.table = table
        coordinator.dialect = dialect
        if coordinator.revision != revision {
            coordinator.revision = revision
            coordinator.show(result)
        }
    }
}

final class ResultTableView: NSTableView {
    weak var coordinator: ResultGridCoordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copy(rows: selectedRowIndexes, as: nil)
    }
}

@MainActor
final class ResultGridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var tableView: ResultTableView?
    var revision = -1
    var table = TableRef(name: "result")
    var dialect: SQLDialect = .sqlite
    private var result = QueryResult(columns: [], rows: [])
    private var categories: [ColumnCategory] = []
    private var scales: [Int?] = []

    func show(_ result: QueryResult) {
        guard let tableView else { return }
        self.result = result
        categories = result.columns.enumerated().map { index, column in
            let named = ColumnCategory(typeName: column.typeName ?? "")
            if named != .text && named != .other { return named }
            // SQLite often has no type for computed columns: judge by the values.
            let sample = result.rows.lazy.compactMap { $0.indices.contains(index) && !$0[index].isNull ? $0[index] : nil }.first
            switch sample {
            case .integer?: return .integer
            case .real?: return .decimal
            default: return named
            }
        }
        scales = result.columns.enumerated().map { index, column in
            guard categories[index] == .decimal, let type = column.typeName, let open = type.firstIndex(of: ","), let close = type.firstIndex(of: ")") else { return nil }
            return Int(type[type.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
        }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for (index, info) in result.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            let header = GridHeaderCell(textCell: info.name)
            header.name = info.name
            header.numeric = categories[index].isNumeric
            column.headerCell = header
            column.width = width(of: index)
            column.minWidth = 48
            column.maxWidth = 1_200
            column.headerToolTip = [info.name, info.typeName].compactMap { $0 }.joined(separator: " · ")
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
        tableView.scrollRowToVisible(0)
    }

    private func width(of index: Int) -> CGFloat {
        let header = CGFloat(result.columns[index].name.count) * 7.4 + 30
        let longest = result.rows.prefix(60).map { $0.indices.contains(index) ? GridStyle.display($0[index]).count : 0 }.max() ?? 0
        return min(max(header, CGFloat(longest) * 7.3 + 24, 80), 360)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        result.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = Int(tableColumn.identifier.rawValue), result.rows.indices.contains(row) else { return nil }
        let view = tableView.makeView(withIdentifier: GridCoordinator.cell, owner: nil) as? GridCellView ?? {
            let view = GridCellView()
            view.identifier = GridCoordinator.cell
            return view
        }()
        let values = result.rows[row]
        let category = categories[index]
        view.configure(
            value: values.indices.contains(index) ? values[index] : .null,
            numeric: category.isNumeric,
            scale: scales[index],
            dateTime: false,
            mark: .none,
            struck: false
        )
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        GridRowView()
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }

    // MARK: Copying

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView, tableView.clickedRow >= 0 else { return }
        let rows = tableView.selectedRowIndexes.contains(tableView.clickedRow) ? tableView.selectedRowIndexes : IndexSet(integer: tableView.clickedRow)
        let one = rows.count == 1
        let copy = NSMenuItem(title: one ? String(localized: "Copy row") : String(localized: "Copy \(rows.count) rows"),
                              action: #selector(MenuAction.run), keyEquivalent: "c")
        let copyAction = MenuAction { [weak self] in self?.copy(rows: rows, as: nil) }
        copy.target = copyAction
        copy.representedObject = copyAction
        menu.addItem(copy)
        let copyAs = NSMenuItem(title: one ? String(localized: "Copy row as") : String(localized: "Copy \(rows.count) rows as"),
                                action: nil, keyEquivalent: "")
        let formats = NSMenu()
        for format in ExportFormat.allCases {
            let action = MenuAction { [weak self] in self?.copy(rows: rows, as: format) }
            let item = NSMenuItem(title: format.title, action: #selector(MenuAction.run), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            formats.addItem(item)
        }
        copyAs.submenu = formats
        menu.addItem(copyAs)
    }

    /// Copies rows as tab-separated text with a header, or in an export format.
    func copy(rows indexes: IndexSet, as format: ExportFormat?) {
        let rows = indexes.compactMap { result.rows.indices.contains($0) ? result.rows[$0] : nil }
        guard !rows.isEmpty else { return }
        GridCoordinator.setClipboard(Self.text(result, rows: rows, format: format, table: table, dialect: dialect, categories: categories))
    }

    static func text(_ result: QueryResult, rows: [[CellValue]], format: ExportFormat?, table: TableRef, dialect: SQLDialect, categories: [ColumnCategory]? = nil) -> String {
        guard let format else {
            var lines = [result.columns.map(\.name).joined(separator: "\t")]
            lines += rows.map { $0.map { GridStyle.display($0) }.joined(separator: "\t") }
            return lines.joined(separator: "\n")
        }
        let columns = result.columns.enumerated().map { index, column in
            ExportColumn(name: column.name, category: categories?[index] ?? ColumnCategory(typeName: column.typeName ?? ""))
        }
        return RowWriter.text(format, columns: columns, rows: rows, table: table, dialect: dialect)
    }
}
