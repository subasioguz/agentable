import AppKit
import Foundation
import Observation
import AgentableCore

/// The SQL tab of one table: the text, what the last run returned, and the file it is saved in.
///
/// Reads run on the person's read-only session and go to the audit log as "you", which is the
/// tab's history. Statements that write are tried in a transaction that is always rolled back,
/// then wait with the person's other changes until they save.
@MainActor
@Observable
final class SQLDocument {
    enum Output: Hashable { case results, plan, messages }

    struct Message: Identifiable, Hashable {
        let id = UUID()
        let at = Date.now
        let text: String
        let isError: Bool
    }

    /// Rows a read shows; more are cut off with a note.
    static let maxRows = 1_000

    @ObservationIgnored weak var grid: GridModel?
    var text: String {
        didSet { if text != oldValue { textChanged() } }
    }
    /// The editor's selection in UTF-16 units, as `NSTextView` reports it.
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    private(set) var file: URL?
    private(set) var result: QueryResult?
    /// Bumps with each result, so the result grid reloads.
    private(set) var resultRevision = 0
    private(set) var plan: String?
    private(set) var messages: [Message] = []
    var output: Output = .results
    private(set) var running = false

    /// Suggestions the person took or dismissed here, hidden before the log catches up.
    private(set) var settled: Set<String> = []
    /// The editor showing this document, for changes that should be undoable there.
    @ObservationIgnored weak var editor: SQLEditorCoordinator?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var describeTask: Task<Void, Never>?
    @ObservationIgnored private var loadingFile = false

    init(grid: GridModel) {
        self.grid = grid
        text = SQLFormatter.pretty(grid.query.displaySQL(limit: 100)) + ";\n"
        selection = NSRange(location: (text as NSString).length, length: 0)
    }

    var fileName: String? { file?.lastPathComponent }

    // MARK: Agents' suggestions

    /// The newest waiting suggestion for this saved query.
    var suggestion: SQLSuggestion? {
        guard let fileName, let workspace = grid?.workspace else { return nil }
        return workspace.suggestions.last { $0.query == fileName && !settled.contains($0.id) }
    }

    /// The suggestion was made for different text than the editor holds now.
    var suggestionIsStale: Bool {
        guard let suggestion else { return false }
        return suggestion.base.trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func acceptSuggestion() {
        guard let suggestion, let workspace = grid?.workspace else { return }
        settled.insert(suggestion.id)
        workspace.accept(suggestion, in: self)
    }

    func dismissSuggestion() {
        guard let suggestion, let workspace = grid?.workspace else { return }
        settled.insert(suggestion.id)
        workspace.dismiss(suggestion)
    }

    // MARK: Asking an agent

    /// The last request sent to an agent from this tab, while it runs and after it answers.
    private(set) var askRun: AskRun?
    /// ⌘I asks the screen to open the Ask box.
    var askRequested = false

    /// Starts the person's Claude Code on this query with `request`. An unsaved query is saved
    /// first under `name`, so the agent can read it.
    func ask(_ request: String, saveAs name: String?) throws {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, let workspace = grid?.workspace, let app = workspace.app else { return }
        if file == nil { try save(named: name ?? "") }
        guard let file, let fileName else { return }
        // The agent reads the file, so it must hold what the editor shows.
        saveTask?.cancel()
        try Data(text.utf8).write(to: file, options: .atomic)
        askRun?.stop()
        let run = AskRun(request: request, query: fileName)
        askRun = run
        let profile = workspace.profile
        Task {
            try? await app.state.record(AuditEvent(connection: profile.name, client: "you", action: .asked, sql: "", detail: "\(run.agent): \(request)"))
            await app.feed.refresh()
        }
        run.start(connection: profile, home: app.paths.root) { [weak app] in
            await app?.feed.refresh()
            return app?.feed.suggestions(on: profile.name).contains { $0.query == fileName && $0.createdAt >= run.startedAt.addingTimeInterval(-2) } == true
        }
    }

    func stopAsking() {
        askRun?.stop()
    }

    /// Closes the card after an answer or a failure.
    func closeAsk() {
        askRun?.stop()
        askRun = nil
    }

    /// Replaces the whole text as one step the editor can undo.
    func take(_ sql: String) {
        if let editor, editor.replaceAllUndoably(sql) { return }
        text = sql
    }


    var resultSummary: String? {
        guard let result else { return nil }
        let rows = result.rows.count
        let count = rows == 1 && !result.truncated
            ? String(localized: "1 row")
            : String(localized: "\(rows.grouped + (result.truncated ? "+" : "")) rows")
        return count + " · \(Int(result.elapsedMilliseconds.rounded())) ms"
    }

    // MARK: Running

    /// Runs the statement under the cursor, or the selected one.
    func run() {
        guard !running, let grid, let workspace = grid.workspace, let app = workspace.app, let browser = workspace.browser,
              let statement = pickStatement(dialect: workspace.dialect) else { return }
        running = true
        Task {
            switch statement.kind {
            case .write, .schema:
                await stage(statement, grid: grid, workspace: workspace, app: app)
            case .transaction, .session:
                say(String(localized: "Each run is its own transaction, so \(statement.verb) isn't needed here."), error: true)
            case .read, .other:
                await read(statement.text, browser: browser, workspace: workspace, app: app)
            }
            running = false
        }
    }

    /// Shows how the database would run the statement under the cursor.
    func explain() {
        guard !running, let workspace = grid?.workspace, let browser = workspace.browser,
              let statement = pickStatement(dialect: workspace.dialect) else { return }
        let postgres = workspace.dialect == .postgres
        running = true
        Task {
            do {
                let sql = (postgres ? "EXPLAIN " : "EXPLAIN QUERY PLAN ") + statement.text
                let result = try await browser.session.run(BoundSQL(sql), options: QueryOptions(readOnly: true, maxRows: 500, timeout: .seconds(30)))
                plan = postgres ? result.rows.compactMap { $0.first?.displayText }.joined(separator: "\n") : Self.sqlitePlan(result)
                output = .plan
            } catch {
                say("\(error)", error: true)
            }
            running = false
        }
    }

    func format() {
        text = SQLFormatter.pretty(text)
    }

    private func read(_ sql: String, browser: TableBrowser, workspace: WorkspaceModel, app: AppModel) async {
        let profile = workspace.profile
        do {
            let options = QueryOptions(readOnly: true, maxRows: Self.maxRows, timeout: .seconds(max(profile.limits.timeoutSeconds, 30)))
            let result = try await browser.session.run(BoundSQL(sql), options: options)
            self.result = result
            resultRevision += 1
            output = .results
            let rows = result.rows.count
            let milliseconds = Int(result.elapsedMilliseconds.rounded())
            say(result.truncated
                ? String(localized: "More than \(Self.maxRows.grouped) rows; the first \(Self.maxRows.grouped) are shown.")
                : rows == 1
                    ? String(localized: "1 row in \(milliseconds) ms.")
                    : String(localized: "\(rows.grouped) rows in \(milliseconds) ms."))
            try? await app.state.record(AuditEvent(
                connection: profile.name, client: "you", action: .read, sql: sql, rows: rows, elapsedMilliseconds: result.elapsedMilliseconds
            ))
            await app.feed.refresh()
        } catch {
            say("\(error)", error: true)
        }
    }

    /// A statement that writes waits with the person's changes, after a trial run tells what it does.
    private func stage(_ statement: SQLStatement, grid: GridModel, workspace: WorkspaceModel, app: AppModel) async {
        do {
            let trial = try await app.review.trial(connection: workspace.profile.name, sql: statement.text)
            let target = SQLAnalyzer.writeTarget(of: statement.text, dialect: workspace.dialect)
                .map { TableRef(schema: $0.schema, name: $0.name) } ?? grid.table
            let rows = trial.rowsChanged
            let note = statement.kind == .schema
                ? String(localized: "ran in a trial")
                : rows == 1 ? String(localized: "would change 1 row") : String(localized: "would change \(rows.grouped) rows")
            let change = RowChange(table: target, key: [], kind: .sql(statement.text))
            workspace.recordingUndo("SQL Change") { workspace.stage(change, note: ChangeNote(detail: note)) }
            let production = workspace.profile.environment == .production
            say(production
                ? String(localized: "Waiting with your changes: in a trial it \(note). ⌘S saves it, after showing you the SQL.")
                : String(localized: "Waiting with your changes: in a trial it \(note). ⌘S saves it."))
        } catch {
            say("\(error)", error: true)
        }
    }

    /// The statement to run: the selection, or the one the cursor is in.
    private func pickStatement(dialect: SQLDialect) -> SQLStatement? {
        let ns = text as NSString
        let selected = NSIntersectionRange(selection, NSRange(location: 0, length: ns.length))
        let source: String
        if selected.length > 0, !ns.substring(with: selected).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = ns.substring(with: selected)
        } else {
            let index = String.Index(utf16Offset: min(selection.location, ns.length), in: text)
            let offset = text.utf8.distance(from: text.startIndex, to: index)
            guard let range = SQLAnalyzer.statement(at: offset, in: text, dialect: dialect) else {
                say(String(localized: "Nothing to run here."), error: true)
                return nil
            }
            source = String(decoding: Array(text.utf8)[range], as: UTF8.self)
        }
        let statements = SQLAnalyzer.statements(in: source, dialect: dialect)
        guard statements.count == 1, let statement = statements.first else {
            say(statements.isEmpty
                ? String(localized: "Nothing to run here.")
                : String(localized: "That selection holds \(statements.count) statements. Select one, or put the cursor in it."), error: true)
            return nil
        }
        return statement
    }

    private func say(_ text: String, error: Bool = false) {
        messages.insert(Message(text: text, isError: error), at: 0)
        if messages.count > 50 { messages.removeLast() }
        if error { output = .messages }
    }

    /// SQLite's plan rows (id, parent, unused, detail) as an indented tree.
    private static func sqlitePlan(_ result: QueryResult) -> String {
        var depth: [Int64: Int] = [:]
        return result.rows.compactMap { row -> String? in
            guard row.count >= 4, case .integer(let id) = row[0], case .integer(let parent) = row[1] else { return row.last?.displayText }
            let level = (depth[parent] ?? -1) + 1
            depth[id] = level
            return String(repeating: "  ", count: level) + row[3].displayText
        }.joined(separator: "\n")
    }

    // MARK: Files

    /// Saves the text as `<name>.sql` in the connection's query folder; later edits save themselves.
    func save(named name: String) throws {
        guard let workspace = grid?.workspace, let folder = workspace.queriesFolder else { return }
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".sql") { base = String(base.dropLast(4)) }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !base.isEmpty, !base.hasPrefix(".") else { throw DatabaseError.unsupported(String(localized: "Give the query a name.")) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appending(path: base + ".sql")
        try Data(text.utf8).write(to: url, options: .atomic)
        file = url
        workspace.reloadSavedQueries()
    }

    /// Opens a saved query. A file that doesn't exist yet opens empty: an agent suggested a new
    /// query under that name, and taking the suggestion saves it.
    func open(_ url: URL) {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let contents = exists ? try? String(contentsOf: url, encoding: .utf8) : "" else { return }
        loadingFile = true
        file = url
        text = contents
        loadingFile = false
        selection = NSRange(location: (text as NSString).length, length: 0)
    }

    /// Puts SQL from the history in the editor, as a new unsaved query.
    func load(_ sql: String) {
        loadingFile = true
        file = nil
        text = sql.hasSuffix(";") ? sql + "\n" : sql + ";\n"
        loadingFile = false
        selection = NSRange(location: (text as NSString).length, length: 0)
    }

    func newQuery() {
        loadingFile = true
        file = nil
        text = ""
        loadingFile = false
        selection = NSRange(location: 0, length: 0)
    }

    private func textChanged() {
        prefetchDescriptions()
        guard !loadingFile, let file else { return }
        saveTask?.cancel()
        let contents = text
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? Data(contents.utf8).write(to: file, options: .atomic)
            self?.grid?.workspace?.reloadSavedQueries()
        }
    }

    // MARK: Completion

    /// Tables named in the text get described, so their columns can be offered.
    private func prefetchDescriptions() {
        describeTask?.cancel()
        let text = text.lowercased()
        describeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, let workspace = grid?.workspace else { return }
            for table in workspace.tables where SQLText.mentions(text, table.name.lowercased()) {
                _ = await workspace.describe(TableRef(table))
            }
        }
    }

    /// What to offer for the word being typed: columns of the tables in the query first, then
    /// tables, then keywords. After `alias.` only that table's columns.
    func completions(prefix: String, qualifier: String?) -> [Completion] {
        guard let workspace = grid?.workspace else { return [] }
        let lower = prefix.lowercased()
        func matches(_ name: String) -> Bool { lower.isEmpty || name.lowercased().hasPrefix(lower) }

        let tables = workspace.tables
        if let qualifier {
            let aliases = Self.aliases(in: text)
            let name = aliases[qualifier.lowercased()] ?? qualifier
            guard let table = tables.first(where: { $0.name.lowercased() == name.lowercased() }),
                  let description = workspace.descriptions[TableRef(table)] else { return [] }
            return description.columns.filter { matches($0.name) }
                .map { Completion(text: $0.name, detail: GridModel.shortType($0.type), kind: .column) }
        }

        var items: [Completion] = []
        var seen = Set<String>()
        let mentioned = tables.filter { SQLText.mentions(text.lowercased(), $0.name.lowercased()) }
        for table in mentioned {
            for column in workspace.descriptions[TableRef(table)]?.columns ?? [] where matches(column.name) && !seen.contains(column.name) {
                seen.insert(column.name)
                items.append(Completion(text: column.name, detail: "\(table.name) · \(GridModel.shortType(column.type))", kind: .column))
            }
        }
        guard !lower.isEmpty else { return items }
        items += tables.filter { matches($0.name) }.map { Completion(text: $0.name, detail: $0.kind == .view ? String(localized: "view") : String(localized: "table"), kind: .table) }
        let keywords = SQLAnalyzer.keywords.filter { $0.lowercased().hasPrefix(lower) }.sorted()
        let lowercase = prefix == lower
        items += keywords.map { Completion(text: lowercase ? $0.lowercased() : $0, detail: String(localized: "keyword"), kind: .keyword) }
        return Array(items.prefix(50))
    }

    /// Aliases in FROM and JOIN clauses: `orders o` and `orders AS o` map `o` to `orders`.
    static func aliases(in sql: String) -> [String: String] {
        let pattern = #"(?i)\b(?:from|join|update|into)\s+("[^"]+"|[A-Za-z_][\w$]*)(?:\.("[^"]+"|[A-Za-z_][\w$]*))?(?:\s+(?:as\s+)?([A-Za-z_][\w$]*))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = sql as NSString
        var map: [String: String] = [:]
        for match in regex.matches(in: sql, range: NSRange(location: 0, length: ns.length)) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard let first = group(1) else { continue }
            let table = group(2) ?? first
            map[table.lowercased()] = table
            if let alias = group(3), !SQLAnalyzer.keywords.contains(alias.uppercased()) {
                map[alias.lowercased()] = table
            }
        }
        return map
    }
}

/// One suggestion while typing SQL.
struct Completion: Hashable {
    enum Kind: Hashable { case column, table, keyword }
    let text: String
    let detail: String
    let kind: Kind

    /// The text to insert: names that need quotes get them.
    var insertion: String {
        guard kind != .keyword else { return text }
        let plain = text.range(of: #"^[a-z_][a-z0-9_]*$"#, options: .regularExpression) != nil
        return plain && !SQLAnalyzer.keywords.contains(text.uppercased()) ? text : SQLBuilder.quote(text)
    }
}
