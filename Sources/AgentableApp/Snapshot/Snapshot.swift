import AppKit
import SwiftUI
import AgentableCore

/// Renders a screen to a PNG and quits, for checking the interface without clicking through it.
///
///     AGENTABLE_HOME=/tmp/demo AGENTABLE_SNAPSHOT=out.png AGENTABLE_SNAPSHOT_SCENE=workspace AgentableApp
///
/// Scenes: `connections`, `new-connection`, `agents`, `welcome`, `welcome-agents`, `workspace`, `filter`,
/// `advanced`, `where`, `structure`, `pages`, `columns`, `sql`, `sql-ask`, `export`, `new-row`, `row-detail`, `review`, `edit-review`, and
/// `apply-edit` (writes the demo edit), `structure-edit` (turns down the demo's row proposal) and
/// `sql-suggest` (an agent's suggestion for a saved query), which run last. `AGENTABLE_APPEARANCE=dark` renders the dark theme;
/// `AGENTABLE_SNAPSHOT_TABLE` opens another table than `orders`.
/// Only reads `AGENTABLE_*` variables and never writes outside `AGENTABLE_HOME`.
@MainActor
enum Snapshot {
    static let environment = ProcessInfo.processInfo.environment
    static var isActive: Bool { environment["AGENTABLE_SNAPSHOT"] != nil }
    static var scene: String { environment["AGENTABLE_SNAPSHOT_SCENE"] ?? "connections" }
    /// Lets views that normally open on a click start open.
    static var openNewConnection: Bool { isActive && scene == "new-connection" }

    private static var started = false

    static func runIfRequested(_ app: AppModel) {
        guard isActive, !started, let output = environment["AGENTABLE_SNAPSHOT"] else { return }
        started = true
        Task {
            await prepare(app)
            try? await Task.sleep(for: .milliseconds(1_200))
            capture(to: URL(fileURLWithPath: output))
            NSApp.terminate(nil)
        }
    }

    private static func prepare(_ app: AppModel) async {
        await app.feed.poll()
        let connection = environment["AGENTABLE_SNAPSHOT_CONNECTION"] ?? app.profiles.first?.name
        switch scene {
        case "welcome", "welcome-agents":
            app.screen = .welcome
        case "connections", "new-connection", "agents":
            app.screen = .connections
        default:
            guard let profile = app.profiles.first(where: { $0.name == connection }) else { return }
            app.open(profile, table: environment["AGENTABLE_SNAPSHOT_TABLE"] ?? "orders")
            guard let workspace = app.workspace else { return }
            for _ in 0..<50 where workspace.status == .connecting || workspace.tables.isEmpty || workspace.currentTable == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let table = workspace.currentTable else { return }
            workspace.expanded.insert(table)
            _ = await workspace.describe(table)
            let grid = workspace.grid(for: table)
            for _ in 0..<50 where grid.columns.isEmpty || grid.loadingFirstPage {
                try? await Task.sleep(for: .milliseconds(100))
            }
            grid.sort = [SortKey(column: "id", ascending: false)]
            for _ in 0..<50 where grid.loadingFirstPage {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await stageDemoEdit(grid)
            switch scene {
            case "filter", "filter-id", "filter-total":
                grid.filter.append(FilterCondition(column: "created_at", category: .dateTime, op: .inLast, values: [.integer(7), .text("days")]))
                grid.filter.append(FilterCondition(column: "status", category: .text, op: .isAnyOf, values: [.text("paid"), .text("shipped")]))
                grid.filter.append(FilterCondition(column: "total", category: .decimal, op: .greaterThan, values: [.text("100")]))
                if scene == "filter-id" {
                    grid.filter.append(FilterCondition(column: "id", category: .integer, op: .isAnyOf, values: [.text("84211"), .text("84209")]))
                }
                SnapshotHooks.openValuePickerFor = ["filter": "status", "filter-id": "id", "filter-total": "total"][scene]
            case "advanced":
                var filter = TableFilter()
                filter.append(FilterCondition(column: "created_at", category: .dateTime, op: .inLast, values: [.integer(7), .text("days")]))
                filter.append(FilterCondition(column: "status", category: .text, op: .isAnyOf, values: [.text("paid"), .text("shipped")]))
                filter.root.items.append(.group(FilterGroup(conjunction: .or, items: [
                    .condition(FilterCondition(column: "total", category: .decimal, op: .greaterThan, values: [.text("100")])),
                    .condition(FilterCondition(column: "channel", category: .text, op: .isAnyOf, values: [.text("ios")])),
                ])))
                grid.filter = filter
                grid.filterMode = .advanced
            case "where":
                grid.filter.append(FilterCondition(column: "status", category: .text, op: .isAnyOf, values: [.text("paid")]))
                grid.filterMode = .sql
            case "export":
                grid.filter.append(FilterCondition(column: "created_at", category: .dateTime, op: .inLast, values: [.integer(7), .text("days")]))
                grid.filter.append(FilterCondition(column: "status", category: .text, op: .isAnyOf, values: [.text("paid"), .text("shipped")]))
                grid.selectRows = IndexSet(0..<3)
                await settle(grid)
            case "new-row":
                await stageNewRows(grid)
            case "pages":
                grid.showPage(6)
                await settle(grid)
            case "columns":
                if let at = grid.columns.firstIndex(where: { $0.name == "channel" }) { grid.columns[at].hidden = true }
            case "sql", "sql-suggest", "sql-ask":
                let queries = [
                    ("at-risk-customers.sql", "SELECT c.id, c.name, count(o.id) AS orders\nFROM customers c\nLEFT JOIN orders o ON o.customer_id = c.id\nGROUP BY c.id, c.name\nHAVING count(o.id) = 0;\n"),
                    ("cohort_retention.sql", "SELECT substr(created_at, 1, 7) AS month, count(*) AS customers\nFROM customers\nGROUP BY 1\nORDER BY 1 DESC;\n"),
                    ("charged-twice.sql", Self.chargedTwice),
                ]
                if let folder = workspace.queriesFolder {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for (name, sql) in queries {
                        // sql-suggest: snapshot.sh saved the query an agent made a suggestion for.
                        if scene == "sql-suggest", FileManager.default.fileExists(atPath: folder.appending(path: name).path) { continue }
                        try? Data(sql.utf8).write(to: folder.appending(path: name))
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
                grid.viewTab = .sql
                if let url = workspace.queriesFolder?.appending(path: "charged-twice.sql") { grid.sql.open(url) }
                grid.sql.run()
                for _ in 0..<50 where grid.sql.running || grid.sql.result == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            case "row-detail":
                grid.cameFrom = BackLink(table: TableRef(name: "customers"), key: "5")
                var filter = TableFilter()
                filter.append(FilterCondition(column: "customer_id", category: .integer, op: .isAnyOf, values: [.integer(5)]))
                grid.filter = filter
                grid.selectRows = IndexSet(integer: 0)
                workspace.showRow = true
                await settle(grid)
            case "structure-edit":
                // The design's board: a new column, a changed default and an agent's proposed index.
                for proposal in workspace.pending where !WorkspaceModel.isDDL(proposal, dialect: workspace.dialect) {
                    await workspace.reject(proposal, note: "Not now")
                }
                grid.viewTab = .structure
                let id = workspace.addColumn(to: table)
                workspace.updateStagedSchema(id, .addColumn(ColumnShape(name: "gift_note", type: "text")))
                if workspace.dialect == .postgres, let currency = grid.description?.columns.first(where: { $0.name == "currency" }) {
                    var new = ColumnShape(currency)
                    new.defaultValue = "'USD'"
                    workspace.editColumn(ColumnShape(currency), to: new, in: table)
                }
                grid.structureSelection = .column("status")
            case "review":
                workspace.openReview()
            case "edit-review":
                workspace.openReview(selecting: workspace.staged.first?.id.uuidString)
            case "apply-edit":
                // Applies only the person's edit (proposals left out, so no Touch ID), then shows the result.
                workspace.excluded = Set(workspace.pending.map(\.id))
                await workspace.applyIncluded()
                for _ in 0..<50 where grid.loadingFirstPage {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            default:
                break
            }
        }
    }

    private static func settle(_ grid: GridModel) async {
        for _ in 0..<50 where grid.loadingFirstPage {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A new order being typed, a copy of 84209 and a deleted order, next to the demo edit.
    private static func stageNewRows(_ grid: GridModel) async {
        let loaded = (0..<20).compactMap { grid.row($0) }
        func order(_ id: Int64) -> [CellValue]? { loaded.first { grid.value(row: $0, column: "id") == .integer(id) } }
        guard let id = grid.addRow() else { return }
        for (column, text) in [("id", "84214"), ("customer_id", "5"), ("status", "pending"), ("total", "129.00"), ("currency", "EUR"), ("channel", "web")] {
            guard let info = grid.columns.first(where: { $0.name == column }) else { continue }
            grid.setInsertValue(id, column: column, to: grid.parse(text, for: info))
        }
        if let source = order(84_209) { grid.duplicate([source]) }
        if let gone = order(84_207) { grid.stageDelete(rows: [gone]) }
        grid.pendingEdit = (id, "customer_id")
    }

    static let chargedTwice = """
        -- from your view: orders charged twice
        SELECT o.id, o.status, o.total, o.created_at,
               count(p.id) AS payments
        FROM orders o
        JOIN payments p ON p.order_id = o.id
          AND p.status = 'succeeded'
        GROUP BY o.id, o.status, o.total, o.created_at
        HAVING count(p.id) > 1
        ORDER BY o.created_at DESC;

        """

    /// The person's own edit in the demo: one order marked delivered.
    private static func stageDemoEdit(_ grid: GridModel) async {
        guard environment["AGENTABLE_SNAPSHOT_EDIT"] != "0", scene != "structure-edit" else { return }
        for index in 0..<12 {
            guard let row = grid.row(index), let status = grid.value(row: row, column: "status") else { continue }
            if status == .text("shipped") {
                grid.stageEdit(row: row, column: "status", to: .text("delivered"))
                return
            }
        }
    }

    /// Draws the whole window, title bar included, into a PNG.
    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Small switches the snapshot sets for views that open things on click.
@MainActor
enum SnapshotHooks {
    static var openValuePickerFor: String?
    static var showStructure: Bool { Snapshot.isActive && Snapshot.scene == "structure" }
    static var openExport = Snapshot.isActive && Snapshot.scene == "export"
    static var openColumns = Snapshot.isActive && Snapshot.scene == "columns"
    static var openAsk = Snapshot.isActive && Snapshot.scene == "sql-ask"
    static var openPages = Snapshot.isActive && Snapshot.scene == "pages"
}
