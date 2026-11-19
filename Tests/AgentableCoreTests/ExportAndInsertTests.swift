import Foundation
import Testing
@testable import AgentableCore

@Suite struct ExportAndInsertTests {
    let orders = TableRef(name: "orders")

    let columns = [
        ExportColumn(name: "id", category: .integer),
        ExportColumn(name: "name", category: .text),
        ExportColumn(name: "total", category: .decimal),
        ExportColumn(name: "meta", category: .json),
        ExportColumn(name: "ok", category: .boolean),
        ExportColumn(name: "data", category: .binary),
    ]

    let rows: [[CellValue]] = [
        [.integer(1), .text("Mara, \"M\"\nLindqvist"), .text("129.00"), .text(#"{"a":1}"#), .text("t"), .blob(Data([0x01, 0xAB]))],
        [.integer(2), .null, .real(64.5), .text("not json"), .bool(false), .null],
    ]

    func text(_ format: ExportFormat, _ dialect: SQLDialect = .sqlite) -> String {
        RowWriter.text(format, columns: columns, rows: rows, table: orders, dialect: dialect)
    }

    @Test func csvQuotesOnlyWhatNeedsIt() {
        #expect(text(.csv) == """
            id,name,total,meta,ok,data
            1,"Mara, ""M""
            Lindqvist",129.00,"{""a"":1}",t,\\x01ab
            2,,64.5,not json,false,

            """)
    }

    @Test func jsonKeepsTypesAndEmbedsJSONColumns() throws {
        let json = text(.json)
        #expect(json == #"""
            [
              {"id": 1, "name": "Mara, \"M\"\nLindqvist", "total": 129.00, "meta": {"a":1}, "ok": true, "data": "\\x01ab"},
              {"id": 2, "name": null, "total": 64.5, "meta": "not json", "ok": false, "data": null}
            ]

            """#)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(parsed.count == 2)
        #expect(RowWriter.text(.json, columns: columns, rows: [], table: orders, dialect: .sqlite) == "[]\n")
    }

    @Test func sqlInsertsReadBackPerEngine() {
        #expect(text(.sqlInsert) == """
            INSERT INTO "orders" ("id", "name", "total", "meta", "ok", "data") VALUES (1, 'Mara, "M"
            Lindqvist', '129.00', '{"a":1}', 't', x'01ab');
            INSERT INTO "orders" ("id", "name", "total", "meta", "ok", "data") VALUES (2, NULL, 64.5, 'not json', FALSE, NULL);

            """)
        #expect(text(.sqlInsert, .postgres).contains(#"'\x01ab'::bytea"#))
    }

    @Test func decimalsKeepTheirScale() {
        let money = [ExportColumn(name: "total", category: .decimal, scale: 2)]
        let rows: [[CellValue]] = [[.integer(129)], [.real(64.5)], [.text("1204")], [.text("12345678901234567.5")], [.null]]
        #expect(RowWriter.text(.csv, columns: money, rows: rows, table: orders, dialect: .sqlite)
            == "total\n129.00\n64.50\n1204.00\n12345678901234567.50\n\n")
        #expect(RowWriter.text(.json, columns: money, rows: [rows[1]], table: orders, dialect: .sqlite) == "[\n  {\"total\": 64.50}\n]\n")
    }

    @Test func markdownEscapesPipesAndLineBreaks() {
        let shop = [ExportColumn(name: "id", category: .integer), ExportColumn(name: "note", category: .text)]
        let markdown = RowWriter.text(.markdown, columns: shop, rows: [[.integer(1), .text("a | b\nc")], [.integer(2), .null]], table: orders, dialect: .sqlite)
        #expect(markdown == """
            | id | note |
            | ---: | --- |
            | 1 | a \\| b<br>c |
            | 2 |  |

            """)
    }

    @Test func exportsAViewPageByPage() async throws {
        let fixture = try await Fixture(environment: .local)
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let browser = TableBrowser(session: session, engine: .sqlite)
        let query = TableQuery(table: orders, dialect: .sqlite, sort: [SortKey(column: "total", ascending: false)], primaryKey: ["id"])
        let url = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let picked = [ExportColumn(name: "id", category: .integer), ExportColumn(name: "status", category: .text), ExportColumn(name: "total", category: .decimal)]
        let written = try await browser.export(query, columns: picked, format: .csv, to: url, pageSize: 2)
        #expect(written == 3)
        #expect(try String(contentsOf: url, encoding: .utf8) == """
            id,status,total
            3,shipped,312.9
            1,paid,129
            2,paid,64.5

            """)
    }

    @Test func insertsApplyWithDefaults() async throws {
        let fixture = try await Fixture(environment: .production)
        let insert = RowChange(
            table: orders, key: [],
            kind: .insert([KeyValue(column: "id", value: .integer(4)), KeyValue(column: "customer_id", value: .integer(2)), KeyValue(column: "total", value: .text("10.5"))])
        )
        let statement = insert.statement(dialect: .sqlite)
        #expect(statement.text == #"INSERT INTO "orders" ("id", "customer_id", "total") VALUES (?, ?, ?)"#)
        #expect(statement.binds == [.integer(4), .integer(2), .text("10.5")])
        #expect(statement.expectedRows == 1)
        #expect(insert.statement(dialect: .postgres).text == #"INSERT INTO "orders" ("id", "customer_id", "total") VALUES ($1, $2, $3)"#)
        #expect(insert.displaySQL(dialect: .sqlite) == #"INSERT INTO "orders" ("id", "customer_id", "total") VALUES (4, 2, '10.5')"#)
        #expect(RowChange(table: orders, key: [], kind: .insert([])).statement(dialect: .sqlite).text == #"INSERT INTO "orders" DEFAULT VALUES"#)

        let review = ReviewService(gateway: fixture.gateway, authenticator: AlwaysConfirm())
        #expect(try await review.apply(connection: "shop", edits: [insert], proposalIDs: []) == 1)
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let row = try await session.run("SELECT status, total FROM orders WHERE id = 4", options: QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(2)))
        #expect(row.rows == [[.text("pending"), .real(10.5)]])
        let events = try await fixture.gateway.state.loggedEvents(connection: "shop")
        #expect(events.last?.event.detail == "orders new row: insert id 4, customer_id 2, total 10.5")
    }

    @Test func findsKeysPointingAtATable() async throws {
        let fixture = try await Fixture(environment: .local)
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        #expect(try await session.references(to: "customers") == [IncomingReference(table: "orders", column: "customer_id", referencedColumn: "id")])
        #expect(try await session.references(to: "orders").isEmpty)
        let described = try await session.describe(table: "orders")
        #expect(described.foreignKeys.map(\.referencedTable) == ["customers"])
    }
}

@Suite struct TableLayoutTests {
    let columns = ["id", "customer_id", "status", "total"]

    @Test func remembersOrderAndKeepsNewColumns() {
        let layout = TableLayout(order: ["status", "id", "gone"], hidden: ["total", "gone"], widths: ["status": 240])
        #expect(layout.ordered(columns) == ["status", "id", "customer_id", "total"])
        #expect(layout.hiddenColumns(columns) == ["total"])
        #expect(TableLayout(hidden: columns).hiddenColumns(columns).isEmpty)
        #expect(!layout.isDefault(columns: columns))
        #expect(TableLayout(order: columns).isDefault(columns: columns))
    }

    @Test func sortFallsBackToTheDefaultOrder() throws {
        #expect(TableLayout().sortKeys(columns) == nil)
        let picked = TableLayout(sort: [SortKey(column: "gone"), SortKey(column: "total", ascending: false)])
        #expect(picked.sortKeys(columns) == [SortKey(column: "total", ascending: false)])
        #expect(TableLayout(sort: []).sortKeys(columns) == [])
        #expect(DefaultOrder.newestFirst.sort(primaryKey: ["id"]) == [SortKey(column: "id", ascending: false)])
        #expect(DefaultOrder.oldestFirst.sort(primaryKey: []) == [])

        let data = try JSONEncoder().encode(picked)
        #expect(try JSONDecoder().decode(TableLayout.self, from: data) == picked)
    }
}
