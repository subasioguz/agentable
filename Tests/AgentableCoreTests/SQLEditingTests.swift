import Foundation
import Testing
@testable import AgentableCore

@Suite struct SQLEditingTests {
    func text(_ sql: String, _ span: SQLSpan) -> String {
        String(decoding: Array(sql.utf8)[span.range], as: UTF8.self)
    }

    @Test func spansColorKeywordsFunctionsAndComments() {
        let sql = "-- charged twice\nSELECT o.id, count(p.id) AS n FROM orders o WHERE note = 'ğüş' AND n > 1;"
        let spans = SQLAnalyzer.spans(in: sql, dialect: .postgres)
        let kinds = Dictionary(spans.map { (text(sql, $0), $0.kind) }, uniquingKeysWith: { first, _ in first })
        #expect(kinds["-- charged twice"] == .comment)
        #expect(kinds["SELECT"] == .keyword)
        #expect(kinds["count"] == .function)
        #expect(kinds["orders"] == .identifier)
        #expect(kinds["'ğüş'"] == .string)
        #expect(kinds["1"] == .number)
        #expect(spans.first?.kind == .comment)
    }

    @Test func findsTheStatementUnderTheCursor() {
        let sql = "SELECT 1;\n\nUPDATE t SET a = ';' WHERE id = 2;\nSELECT 3"
        let bytes = Array(sql.utf8)
        func statement(at offset: Int) -> String? {
            SQLAnalyzer.statement(at: offset, in: sql, dialect: .postgres).map { String(decoding: bytes[$0], as: UTF8.self) }
        }
        #expect(statement(at: 0) == "SELECT 1")
        #expect(statement(at: 9) == "SELECT 1")
        #expect(statement(at: 15) == "UPDATE t SET a = ';' WHERE id = 2")
        #expect(statement(at: bytes.count) == "SELECT 3")
        #expect(SQLAnalyzer.statement(at: 0, in: "  -- nothing", dialect: .sqlite) == nil)
    }

    @Test func writtenSQLIsTriedThenAppliedAsWritten() async throws {
        let fixture = try await Fixture(environment: .production)
        let review = ReviewService(gateway: fixture.gateway, authenticator: AlwaysConfirm())
        let sql = "UPDATE orders SET status = 'refunded' WHERE status = 'paid'"

        let trial = try await review.trial(connection: "shop", sql: sql)
        #expect(trial.rowsChanged == 2)
        let reader = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let options = QueryOptions(readOnly: true, maxRows: 10, timeout: .seconds(2))
        #expect(try await reader.run("SELECT count(*) FROM orders WHERE status = 'paid'", options: options).rows[0][0] == .integer(2))

        let change = RowChange(table: TableRef(name: "orders"), key: [], kind: .sql(sql))
        #expect(!change.mergesByRow)
        #expect(change.statement(dialect: .sqlite) == BoundSQL(sql))
        #expect(try await review.apply(connection: "shop", edits: [change], proposalIDs: []) == 2)
        #expect(try await reader.run("SELECT count(*) FROM orders WHERE status = 'paid'", options: options).rows[0][0] == .integer(0))
        let events = try await fixture.gateway.state.loggedEvents(connection: "shop")
        #expect(events.last?.event.detail == "orders SQL: \(sql)")
    }
}
