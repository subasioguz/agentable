import Foundation
import Testing
@testable import AgentableCore

@Suite struct BrowseTests {
    let orders = TableRef(name: "orders")

    func condition(_ column: String, _ category: ColumnCategory, _ op: FilterOperator, _ values: [CellValue] = []) -> FilterCondition {
        FilterCondition(column: column, category: category, op: op, values: values)
    }

    @Test func filtersBecomeBoundSQL() {
        var filter = TableFilter()
        filter.append(condition("status", .text, .isAnyOf, [.text("paid"), .text("shipped")]))
        filter.append(condition("total", .decimal, .greaterThan, [.text("100")]))
        filter.append(condition("note", .text, .contains, [.text("50%_off")]))

        let query = TableQuery(table: orders, dialect: .postgres, filter: filter, primaryKey: ["id"])
        let page = query.page(offset: 500, limit: 500)
        #expect(page.text == #"SELECT * FROM "orders" WHERE "status" IN ($1, $2) AND "total" > $3 AND CAST("note" AS text) ILIKE $4 ESCAPE '\' ORDER BY "id" ASC LIMIT 500 OFFSET 500"#)
        #expect(page.binds == [.text("paid"), .text("shipped"), .text("100"), .text(#"%50\%\_off%"#)])

        let sqlite = TableQuery(table: orders, dialect: .sqlite, filter: filter).count()
        #expect(sqlite.text == #"SELECT count(*) FROM "orders" WHERE "status" IN (?, ?) AND "total" > ? AND CAST("note" AS TEXT) LIKE ? ESCAPE '\'"#)
    }

    @Test func groupsAndNullsReadAsWritten() {
        var filter = TableFilter()
        filter.append(condition("status", .text, .isNoneOf, [.text("refunded")]))
        filter.root.items.append(.group(FilterGroup(conjunction: .or, items: [
            .condition(condition("total", .decimal, .greaterThan, [.integer(100)])),
            .condition(condition("tier", .text, .isAnyOf, [.text("vip"), .null])),
        ])))
        #expect(filter.displaySQL(dialect: .postgres)
            == #"("status" <> 'refunded' OR "status" IS NULL) AND ("total" > 100 OR ("tier" = 'vip' OR "tier" IS NULL))"#)
        #expect(filter.sentence == "status is not refunded and (total > 100 or tier is vip or empty)")
        #expect(!filter.isFlat)
        #expect(filter.filteredColumns == ["status", "total", "tier"])
    }

    @Test func incompleteConditionsAreLeftOut() {
        var filter = TableFilter()
        filter.append(condition("status", .text, .isAnyOf))
        #expect(filter.isEmpty)
        #expect(TableQuery(table: orders, dialect: .sqlite, filter: filter).count().text == #"SELECT count(*) FROM "orders""#)
    }

    @Test func quickSearchLooksInEveryTextColumn() {
        var filter = TableFilter()
        filter.append(condition("status", .text, .isAnyOf, [.text("paid")]))
        let query = TableQuery(table: orders, dialect: .postgres, filter: filter, search: "ay", searchColumns: ["name", "email"])
        #expect(query.count().text == #"SELECT count(*) FROM "orders" WHERE ("status" = $1) AND (CAST("name" AS text) ILIKE $2 ESCAPE '\' OR CAST("email" AS text) ILIKE $3 ESCAPE '\')"#)
        #expect(query.count().binds == [.text("paid"), .text("%ay%"), .text("%ay%")])
    }

    @Test func switchedOffConditionsAndGroupsDoNotFilter() {
        var filter = TableFilter()
        filter.append(condition("status", .text, .isAnyOf, [.text("paid")]))
        var off = condition("total", .decimal, .greaterThan, [.integer(100)])
        off.isEnabled = false
        filter.append(off)
        filter.root.items.append(.group(FilterGroup(conjunction: .or, items: [.condition(condition("tier", .text, .isAnyOf, [.text("vip")]))], isEnabled: false)))
        #expect(filter.displaySQL(dialect: .sqlite) == #""status" = 'paid'"#)
        #expect(filter.sentence == "status is paid")
        #expect(filter.filteredColumns == ["status"])
        filter.remove(filter.conditions[0].id)
        #expect(filter.isEmpty)
    }

    @Test func dateWindowsPerDialect() {
        var filter = TableFilter()
        filter.append(condition("created_at", .dateTime, .inLast, [.integer(2), .text("weeks")]))
        var pg = SQLBuilder(dialect: .postgres)
        #expect(filter.sql(&pg) == #""created_at" >= now() - CAST($1 AS interval)"#)
        #expect(pg.binds == [.text("2 weeks")])
        var lite = SQLBuilder(dialect: .sqlite)
        #expect(filter.sql(&lite) == #""created_at" >= datetime('now', ?)"#)
        #expect(lite.binds == [.text("-14 days")])
    }

    @Test func browsesPagesCountsAndValues() async throws {
        let fixture = try await Fixture(environment: .local)
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let browser = TableBrowser(session: session, engine: .sqlite)

        var filter = TableFilter()
        let status = condition("status", .text, .isAnyOf, [.text("paid")])
        filter.append(status)
        filter.append(condition("total", .decimal, .greaterThan, [.text("100")]))
        let query = TableQuery(table: orders, dialect: .sqlite, filter: filter, sort: [SortKey(column: "total", ascending: false)], primaryKey: ["id"])

        let page = try await browser.page(query, offset: 0, limit: 10)
        #expect(page.rows.map { $0[0] } == [.integer(1)])
        #expect(try await browser.count(query) == 1)

        // Values for the status picker ignore the status condition itself but keep the others.
        let values = try await browser.valueCounts(query, column: "status", excluding: status.id)
        #expect(values == [ValueCount(value: .text("paid"), count: 1), ValueCount(value: .text("shipped"), count: 1)])

        let estimates = try await browser.rowEstimates(try await session.tables())
        #expect(estimates[orders] == 3)
        #expect(estimates[TableRef(name: "customers")] == 2)
    }

    @Test func stagedEditsApplyOnceAndRefuseStaleRows() async throws {
        let fixture = try await Fixture(environment: .production)
        let edit = RowChange(
            table: orders,
            key: [KeyValue(column: "id", value: .integer(3))],
            kind: .update([ColumnChange(column: "status", category: .text, old: .text("shipped"), new: .text("delivered"))])
        )
        let statement = edit.statement(dialect: .sqlite)
        #expect(statement.text == #"UPDATE "orders" SET "status" = ? WHERE "id" = ? AND "status" IS ?"#)
        #expect(statement.expectedRows == 1)
        #expect(edit.statement(dialect: .postgres).text == #"UPDATE "orders" SET "status" = $1 WHERE "id" = $2 AND "status" IS NOT DISTINCT FROM $3"#)
        #expect(statement.binds == [.text("delivered"), .integer(3), .text("shipped")])

        let review = ReviewService(gateway: fixture.gateway, authenticator: AlwaysConfirm())
        #expect(try await review.apply(connection: "shop", edits: [edit], proposalIDs: []) == 1)

        // Applying the same edit again finds the row already changed and leaves everything as is.
        await #expect(throws: DatabaseError.unexpectedRowCount(expected: 1, actual: 0)) {
            try await review.apply(connection: "shop", edits: [edit], proposalIDs: [])
        }
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let status = try await session.run("SELECT status FROM orders WHERE id = 3", options: QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(2)))
        #expect(status.rows[0][0] == .text("delivered"))

        let events = try await fixture.gateway.state.loggedEvents(connection: "shop")
        #expect(events.map(\.event.action) == [.write, .failed])
        #expect(events[0].event.detail == "orders 3: status shipped → delivered")
        #expect(try await fixture.gateway.state.loggedEvents(connection: "shop", after: events[0].id).count == 1)
    }

    @Test func proposalsCarryAPreviewAndApplyWithEdits() async throws {
        let fixture = try await Fixture(environment: .production, access: .propose, rules: VisibilityRules(maskedColumns: ["orders.total"]))
        let outcome = try await fixture.gateway.query(
            connection: "shop", sql: "UPDATE orders SET status = 'refund_pending' WHERE status = 'paid'", client: "claude-code"
        )
        guard case .proposed(let proposal) = outcome else {
            Issue.record("expected a proposal, got \(outcome)")
            return
        }
        let stored = try #require(try await fixture.gateway.state.proposal(id: proposal.id))
        let preview = try #require(stored.preview)
        #expect(preview.kind == .update && preview.table == "orders")
        #expect(preview.columns == ["id", "customer_id", "status", "total"])
        #expect(preview.rows.map { $0[2] } == ["refund_pending", "refund_pending"])
        #expect(preview.rows.allSatisfy { $0[3] != "129.0" && $0[3] != "64.5" })
        #expect(!(try AgentFormatter.json(stored)).contains("preview"))

        let edit = RowChange(
            table: orders,
            key: [KeyValue(column: "id", value: .integer(3))],
            kind: .update([ColumnChange(column: "total", category: .decimal, old: .real(312.9), new: .text("300"))])
        )
        let review = ReviewService(gateway: fixture.gateway, authenticator: AlwaysConfirm())
        #expect(try await review.apply(connection: "shop", edits: [edit], proposalIDs: [proposal.id]) == 3)
        #expect(try await fixture.gateway.state.proposal(id: proposal.id)?.status == .applied)
    }

    @Test func writeTargets() {
        #expect(SQLAnalyzer.writeTarget(of: "UPDATE public.orders SET a = 1", dialect: .postgres)! == ("public", "orders"))
        #expect(SQLAnalyzer.writeTarget(of: #"DELETE FROM "Order Items" WHERE id = 1"#, dialect: .postgres)! == (nil, "Order Items"))
        #expect(SQLAnalyzer.writeTarget(of: "INSERT OR REPLACE INTO t VALUES (1)", dialect: .sqlite)! == (nil, "t"))
        #expect(SQLAnalyzer.writeTarget(of: "SELECT 1", dialect: .sqlite) == nil)
    }
}
