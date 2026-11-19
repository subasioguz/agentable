import AppKit
import SwiftUI
import AgentableCore

/// A copy or export that may take a while. It lives on the grid, so it keeps going and keeps its
/// result when the panel closes.
@MainActor
@Observable
final class ExportJob {
    enum State: Equatable {
        case idle
        case working(rows: Int)
        case saved(URL, rows: Int)
        case copied(rows: Int)
        case failed(String)
    }

    var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    func run(_ work: @escaping @MainActor (ExportJob) async throws -> State) {
        task?.cancel()
        state = .working(rows: 0)
        task = Task {
            do {
                state = try await work(self)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed("\(error)")
            }
        }
    }

    func progress(_ rows: Int) {
        if isWorking { state = .working(rows: rows) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }
}

/// "Export": a format, which rows, a preview of the first lines, then Copy or Save.
struct ExportPanel: View {
    @Bindable var grid: GridModel
    @State private var format = ExportFormat(rawValue: Defaults.string("exportFormat") ?? "") ?? .csv
    @State private var scope: Scope = .view
    @State private var tablePreview: [[CellValue]] = []

    enum Scope: Hashable { case selected, view, table }

    /// Copying more than this goes through a file instead.
    static let copyLimit = 10_000

    private var job: ExportJob { grid.exportJob }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Export").font(.ui(13, .semibold)).foregroundStyle(Color.tmText)
                HStack(spacing: 0) {
                    Text(grid.table.name).font(.mono(12))
                    Text(grid.visibleColumns.count == 1 ? String(localized: " · 1 visible column") : String(localized: " · \(grid.visibleColumns.count) visible columns")).font(.ui(12.5))
                }
                .foregroundStyle(Color.tmMuted)
            }
            SegmentedSwitch(options: ExportFormat.allCases.map { ($0, $0.title) }, selection: $format, fill: true)
            SegmentedSwitch(options: scopeOptions, selection: $scope, fill: true)
            preview
            footer
        }
        .padding(14)
        .frame(width: 420)
        .onAppear { scope = grid.selectedRows.isEmpty ? .view : .selected }
        .onChange(of: format) { Defaults.set(format.rawValue, "exportFormat") }
        .onChange(of: scope) { if case .copied = job.state { job.state = .idle } }
        .task(id: scope) {
            guard scope == .table, viewIsWholeTable == false, let browser = grid.workspace?.browser else { return }
            let result = try? await browser.page(grid.wholeTableQuery, offset: 0, limit: 3)
            tablePreview = result.map { TableBrowser.project($0, onto: grid.columns.map(\.name)) } ?? []
        }
    }

    // MARK: Scope

    private var scopeOptions: [(value: Scope, label: String)] {
        var options: [(value: Scope, label: String)] = []
        let selected = grid.selectedRows.count
        if selected > 0 { options.append((.selected, String(localized: "Selected · \(selected.grouped)"))) }
        options.append((.view, viewCount.map { String(localized: "This view · \($0.grouped)") } ?? String(localized: "This view")))
        options.append((.table, String(localized: "Whole table")))
        return options
    }

    private var viewCount: Int? {
        guard let count = grid.knownCount, !grid.countIsEstimate else { return nil }
        return count
    }

    private var viewIsWholeTable: Bool { grid.filter.isEmpty && grid.search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Rows in the chosen scope, when known.
    private var total: Int? {
        switch scope {
        case .selected: grid.selectedRows.count
        case .view: viewCount
        case .table: viewIsWholeTable ? viewCount : grid.workspace?.estimates[grid.table]
        }
    }

    private var scopeNote: String {
        switch scope {
        case .selected: String(localized: "The rows you selected")
        case .view: viewIsWholeTable ? wholeTableNote : String(localized: "Filters and sort of this view")
        case .table: wholeTableNote
        }
    }

    private var wholeTableNote: String {
        grid.sort.isEmpty ? String(localized: "Every row, by primary key") : String(localized: "Every row, in this sort")
    }

    // MARK: Preview

    private var previewRows: [[CellValue]] {
        switch scope {
        case .selected: Array(grid.selectedRows.prefix(3))
        case .view: (0..<3).compactMap { grid.loadedRow($0) }
        case .table: viewIsWholeTable ? (0..<3).compactMap { grid.loadedRow($0) } : tablePreview
        }
    }

    private var previewLines: [String] {
        let columns = grid.exportColumns
        var writer = RowWriter(format: format, columns: columns, table: grid.table, dialect: grid.dialect)
        let rows = previewRows.map { row in columns.map { grid.value(row: row, column: $0.name) ?? .null } }
        var text = writer.header() + writer.rows(rows)
        if let total, total <= rows.count { text += writer.footer() }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }

    private var preview: some View {
        let shown = previewRows.count
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(previewLines.prefix(7).enumerated()), id: \.offset) { _, line in
                Text(line).lineLimit(1).truncationMode(.tail).foregroundStyle(Color.tmText2)
            }
            if total.map({ $0 > shown }) ?? true {
                Text(total.map { String(localized: "… \(($0 - shown).grouped) more") } ?? "…").foregroundStyle(Color.tmMuted)
            }
        }
        .font(.mono(11.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tmSide, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.tmLine))
    }

    // MARK: Actions

    private var footer: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 8)
            if job.isWorking {
                Button("Cancel") { job.cancel() }.buttonStyle(.secondary(height: 30))
            } else {
                Button("Copy") { copy() }
                    .buttonStyle(.secondary(height: 30))
                    .disabled(!canCopy)
                    .help(canCopy ? String(localized: "Copy as \(format.title)") : String(localized: "More than \(Self.copyLimit.grouped) rows: save them to a file"))
            }
            Button("Save…") { save() }
                .buttonStyle(.primary(height: 30))
                .disabled(job.isWorking)
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .idle:
            Text(scopeNote).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
        case .working(let rows):
            Text(rows == 0 ? String(localized: "Reading rows…") : String(localized: "\(rows.grouped) rows so far…")).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
        case .copied(let rows):
            Text(rows == 1 ? String(localized: "Copied 1 row") : String(localized: "Copied \(rows.grouped) rows")).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
        case .saved(let url, let rows):
            HStack(spacing: 4) {
                Text(rows == 1 ? String(localized: "Saved 1 row") : String(localized: "Saved \(rows.grouped) rows")).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.text(height: 24, size: 12, color: .tmYou))
            }
        case .failed(let message):
            Text(message).font(.ui(12)).foregroundStyle(Color.tmBad).lineLimit(2).help(message)
        }
    }

    private var canCopy: Bool {
        if scope == .selected { return true }
        return total.map { $0 <= Self.copyLimit } ?? false
    }

    private var scopeQuery: TableQuery {
        scope == .table ? grid.wholeTableQuery : grid.query
    }

    private func copy() {
        let format = format
        if scope == .selected {
            let rows = grid.selectedRows
            GridCoordinator.setClipboard(grid.text(for: rows, format: format))
            job.state = .copied(rows: rows.count)
            return
        }
        guard let browser = grid.workspace?.browser else { return }
        let query = scopeQuery
        let columns = grid.exportColumns
        let table = grid.table
        let dialect = grid.dialect
        job.run { job in
            var rows: [[CellValue]] = []
            while true {
                try Task.checkCancellation()
                let page = try await browser.page(query, offset: rows.count, limit: 5_000)
                rows += TableBrowser.project(page, onto: columns.map(\.name))
                job.progress(rows.count)
                if page.rows.count < 5_000 { break }
                if rows.count > Self.copyLimit { throw DatabaseError.unsupported(String(localized: "More than \(Self.copyLimit.grouped) rows: save them to a file.")) }
            }
            GridCoordinator.setClipboard(RowWriter.text(format, columns: columns, rows: rows, table: table, dialect: dialect))
            return .copied(rows: rows.count)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(grid.table.name).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = format
        if scope == .selected {
            let rows = grid.selectedRows
            let text = grid.text(for: rows, format: format)
            job.run { _ in
                try Data(text.utf8).write(to: url)
                return .saved(url, rows: rows.count)
            }
            return
        }
        guard let browser = grid.workspace?.browser else { return }
        let query = scopeQuery
        let columns = grid.exportColumns
        job.run { job in
            do {
                let rows = try await browser.export(query, columns: columns, format: format, to: url) { rows in
                    Task { @MainActor in job.progress(rows) }
                }
                return .saved(url, rows: rows)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }
}
