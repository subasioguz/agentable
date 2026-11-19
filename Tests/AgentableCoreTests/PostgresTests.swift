import Foundation
import Testing
@testable import AgentableCore

/// Runs against a real server when `AGENTABLE_TEST_POSTGRES_URL` is set, e.g.
/// `postgres://agentable@localhost:55432/postgres?sslmode=disable`.
private let postgresURL = ProcessInfo.processInfo.environment["AGENTABLE_TEST_POSTGRES_URL"]

@Suite(.enabled(if: postgresURL != nil, "set AGENTABLE_TEST_POSTGRES_URL to run"), .serialized)
struct PostgresTests {
    let suffix = String(UUID().uuidString.prefix(8)).lowercased()

    func profile(_ environment: DeploymentEnvironment = .local, rules: VisibilityRules = .init()) throws -> ParsedConnection {
        var parsed = try ConnectionURL.parse(postgresURL!, name: "pg", environment: environment)
        parsed.profile.rules = rules
        return parsed
    }

    func session(readOnly: Bool) async throws -> PostgresSession {
        let parsed = try profile()
        return try await PostgresSession.connect(profile: parsed.profile, password: parsed.password, readOnly: readOnly)
    }

    /// Opens a session, runs `body` and closes the session on every path.
    func using<T>(readOnly: Bool, _ body: (PostgresSession) async throws -> T) async throws -> T {
        let session = try await session(readOnly: readOnly)
        do {
            let value = try await body(session)
            await session.close()
            return value
        } catch {
            await session.close()
            throw error
        }
    }

    func seed() async throws {
        try await cleanup()
        _ = try await using(readOnly: false) { writer in try await writer.apply([
            "CREATE TABLE customers_\(suffix) (id int PRIMARY KEY, name text NOT NULL, email text)",
            "CREATE TABLE orders_\(suffix) (id int PRIMARY KEY, customer_id int REFERENCES customers_\(suffix)(id), status text NOT NULL DEFAULT 'pending', total numeric(10,2), created_at timestamptz DEFAULT now())",
            "CREATE SEQUENCE seq_\(suffix)",
            "INSERT INTO customers_\(suffix) VALUES (1, 'Mara', 'mara@northwind.com'), (2, 'Kenji', 'kenji@kestrel.io')",
            "INSERT INTO orders_\(suffix) (id, customer_id, status, total) VALUES (1, 1, 'paid', 129), (2, 2, 'paid', 64.5), (3, 1, 'shipped', 312.9)",
        ], timeout: .seconds(10)) }
    }

    func cleanup() async throws {
        _ = try await using(readOnly: false) { writer in try await writer.apply([
            "DROP VIEW IF EXISTS paid_\(suffix)", "DROP TABLE IF EXISTS orders_\(suffix)", "DROP TABLE IF EXISTS customers_\(suffix)",
            "DROP SEQUENCE IF EXISTS seq_\(suffix)",
        ], timeout: .seconds(10)) }
    }

    @Test func readsAreLimitedAndGuarded() async throws {
        try await seed()
        try await using(readOnly: true) { reader in
        let options = QueryOptions(readOnly: true, maxRows: 10, timeout: .seconds(5))

        let many = try await reader.run("SELECT g FROM generate_series(1, 1000) g", options: options)
        #expect(many.rows.count == 10)
        #expect(many.truncated)

        let typed = try await reader.run("SELECT o.id, o.total, o.created_at IS NOT NULL AS dated, c.name FROM orders_\(suffix) o JOIN customers_\(suffix) c ON c.id = o.customer_id ORDER BY o.id", options: options)
        #expect(typed.rows.count == 3)
        #expect(typed.rows[0][1] == .text("129"))
        #expect(typed.rows[0][2] == .bool(true))

        // The classifier calls this a read; the read-only transaction still stops it.
        await #expect(throws: DatabaseError.readOnlyViolation) {
            try await reader.run("SELECT nextval('seq_\(suffix)')", options: options)
        }
        await #expect(throws: DatabaseError.readOnlyViolation) {
            try await reader.run("UPDATE orders_\(suffix) SET total = 0", options: options)
        }
        await #expect(throws: DatabaseError.multipleStatements(2)) {
            try await reader.run("SELECT 1; DROP TABLE orders_\(suffix)", options: options)
        }
        await #expect(throws: DatabaseError.self) {
            try await reader.run("SELECT pg_sleep(3)", options: QueryOptions(readOnly: true, maxRows: 1, timeout: .milliseconds(300)))
        }
        }
        try await cleanup()
    }

    @Test func resultColumnsKnowTheirSourceForMasking() async throws {
        try await seed()
        try await using(readOnly: true) { reader in
        let result = try await reader.run(
            "SELECT name, email AS contact FROM customers_\(suffix) ORDER BY id",
            options: QueryOptions(readOnly: true, maxRows: 10, timeout: .seconds(5))
        )
        #expect(result.columns[1].sourceTable == "customers_\(suffix)")
        #expect(result.columns[1].sourceColumn == "email")
        let masked = Masking.columnsToMask(result.columns, rules: VisibilityRules(maskedColumns: ["customers_\(suffix).email"]), mentioned: [])
        #expect(masked == [1])
        }
        try await cleanup()
    }

    @Test func trialRunsRollBackAndApplyCommits() async throws {
        try await seed()
        try await using(readOnly: false) { writer in
        let update = "UPDATE orders_\(suffix) SET status = 'refund_pending' WHERE status = 'paid'"
        #expect(try await writer.dryRun(update, timeout: .seconds(5)) == 2)
        let check = "SELECT count(*) FROM orders_\(suffix) WHERE status = 'refund_pending'"
        let options = QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(5))
        #expect(try await writer.run(check, options: options).rows[0][0] == .integer(0))
        #expect(try await writer.apply([update], timeout: .seconds(5)) == [2])
        #expect(try await writer.run(check, options: options).rows[0][0] == .integer(2))

        let description = try await writer.describe(table: "ORDERS_\(suffix)")
        #expect(description.columns.map(\.name) == ["id", "customer_id", "status", "total", "created_at"])
        #expect(description.columns[0].primaryKey)
        #expect(description.foreignKeys.first?.referencedTable == "customers_\(suffix)")
        #expect(description.indexes.contains { $0.unique && $0.columns == ["id"] })
        }
        try await cleanup()
    }

    @Test func agentRoleReadsOnlyWhatItIsGranted() async throws {
        try await seed()
        let role = "agent_\(suffix)"
        let tables = try await using(readOnly: true) { try await $0.tables() }.filter { $0.name.hasSuffix(suffix) }
        let setup = AgentRole.setupSQL(
            role: role, database: "postgres", tables: tables,
            rules: VisibilityRules(hiddenTables: ["customers_\(suffix)"])
        ).replacingOccurrences(of: "'change-me'", with: "'agent-pw'")
        _ = try await using(readOnly: false) { try await $0.apply(SQLAnalyzer.statements(in: setup, dialect: .postgres).map(\.text), timeout: .seconds(10)) }

        var agent = try profile().profile
        agent.user = role
        let session = try await PostgresSession.connect(profile: agent, password: "agent-pw", readOnly: true)
        let options = QueryOptions(readOnly: true, maxRows: 10, timeout: .seconds(5))
        do {
            #expect(try await session.run("SELECT count(*) FROM orders_\(suffix)", options: options).rows[0][0] == .integer(3))
            await #expect(throws: DatabaseError.self) {
                try await session.run("SELECT * FROM customers_\(suffix)", options: options)
            }
            await session.close()
        } catch {
            await session.close()
            throw error
        }
        _ = try await using(readOnly: false) {
            try await $0.apply(["DROP OWNED BY \(role)", "DROP ROLE \(role)"], timeout: .seconds(10))
        }
        try await cleanup()
    }

    @Test func browsesWithBindsAndAppliesEdits() async throws {
        try await seed()
        let table = TableRef(name: "orders_\(suffix)")
        var filter = TableFilter()
        let status = FilterCondition(column: "status", category: .text, op: .isAnyOf, values: [.text("paid"), .text("shipped")])
        filter.append(status)
        filter.append(FilterCondition(column: "total", category: .decimal, op: .greaterThan, values: [.text("100")]))
        filter.append(FilterCondition(column: "created_at", category: .dateTime, op: .inLast, values: [.integer(7), .text("days")]))
        filter.append(FilterCondition(column: "id", category: .integer, op: .isNoneOf, values: [.integer(99)]))
        let query = TableQuery(table: table, dialect: .postgres, filter: filter, sort: [SortKey(column: "total", ascending: false)], primaryKey: ["id"])

        try await using(readOnly: true) { reader in
            let browser = TableBrowser(session: reader, engine: .postgres)
            #expect(try await browser.page(query, offset: 0, limit: 10).rows.map { $0[0] } == [.integer(3), .integer(1)])
            #expect(try await browser.count(query) == 2)
            let values = try await browser.valueCounts(query, column: "status", excluding: status.id, search: "P")
            #expect(values.map(\.value) == [.text("paid"), .text("shipped")])
            // Calls from several tasks at once share the one connection one at a time.
            async let first = browser.count(query)
            async let second = browser.page(query, offset: 1, limit: 1)
            #expect(try await first == 2)
            #expect(try await second.rows.count == 1)
        }

        let edit = RowChange(
            table: table,
            key: [KeyValue(column: "id", value: .integer(3))],
            kind: .update([
                ColumnChange(column: "status", category: .text, old: .text("shipped"), new: .text("delivered")),
                ColumnChange(column: "total", category: .decimal, old: .text("312.9"), new: .text("300.5")),
            ])
        )
        try await using(readOnly: false) { writer in
            #expect(try await writer.apply([edit.statement(dialect: .postgres)], timeout: .seconds(5)) == [1])
            await #expect(throws: DatabaseError.unexpectedRowCount(expected: 1, actual: 0)) {
                try await writer.apply([edit.statement(dialect: .postgres)], timeout: .seconds(5))
            }
            let trial = try await writer.trialRun("UPDATE orders_\(suffix) SET status = 'refund_pending' WHERE status = 'paid'", timeout: .seconds(5), maxRows: 1)
            #expect(trial.rowsChanged == 2)
            #expect(trial.changed?.rows.count == 1 && trial.changed?.truncated == true)
            #expect(trial.changed?.columns.map(\.name).contains("status") == true)
            let check = try await writer.run("SELECT count(*) FROM orders_\(suffix) WHERE status = 'refund_pending'", options: QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(5)))
            #expect(check.rows[0][0] == .integer(0))
        }
        try await cleanup()
    }

    @Test func findsReferencesInsertsAndExports() async throws {
        try await seed()
        let orders = TableRef(name: "orders_\(suffix)")
        try await using(readOnly: true) { reader in
            #expect(try await reader.references(to: "customers_\(suffix)")
                == [IncomingReference(schema: "public", table: "orders_\(suffix)", column: "customer_id", referencedColumn: "id")])
            let described = try await reader.describe(table: "orders_\(suffix)")
            #expect(described.foreignKeys.first?.referencedSchema == "public")

            let browser = TableBrowser(session: reader, engine: .postgres)
            let query = TableQuery(table: orders, dialect: .postgres, primaryKey: ["id"])
            let url = FileManager.default.temporaryDirectory.appending(path: "pg-export-\(suffix).json")
            defer { try? FileManager.default.removeItem(at: url) }
            // Numerics arrive as numbers; the column's scale puts the trailing zeros back, as the app does.
            let columns = [ExportColumn(name: "id", category: .integer), ExportColumn(name: "total", category: .decimal, scale: 2)]
            #expect(try await browser.export(query, columns: columns, format: .json, to: url, pageSize: 2) == 3)
            let exported = try String(contentsOf: url, encoding: .utf8)
            #expect(exported == """
                [
                  {"id": 1, "total": 129.00},
                  {"id": 2, "total": 64.50},
                  {"id": 3, "total": 312.90}
                ]

                """)
        }
        let insert = RowChange(table: orders, key: [], kind: .insert([KeyValue(column: "id", value: .text("4")), KeyValue(column: "total", value: .text("10.5"))]))
        try await using(readOnly: false) { writer in
            #expect(try await writer.apply([insert.statement(dialect: .postgres)], timeout: .seconds(5)) == [1])
            let row = try await writer.run("SELECT status, total::text, created_at IS NOT NULL FROM orders_\(suffix) WHERE id = 4", options: QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(5)))
            #expect(row.rows == [[.text("pending"), .text("10.50"), .bool(true)]])
        }
        try await cleanup()
    }

    @Test func changesStructureInOneTransaction() async throws {
        try await seed()
        let orders = TableRef(schema: "public", name: "orders_\(suffix)")
        _ = try await using(readOnly: false) { writer in try await writer.apply([
            "ALTER TABLE orders_\(suffix) ADD CONSTRAINT status_\(suffix) CHECK (status IN ('pending', 'paid', 'shipped'))",
            "ALTER TABLE orders_\(suffix) ADD CONSTRAINT total_\(suffix) CHECK (total >= 0)",
            "CREATE VIEW paid_\(suffix) AS SELECT id, total FROM orders_\(suffix) WHERE total > 0",
        ], timeout: .seconds(10)) }
        let before = try await using(readOnly: true) { try await $0.describe(table: orders.path) }
        #expect(before.checks.first { $0.columns == ["status"] }?.allowedValues == ["pending", "paid", "shipped"])
        #expect(before.checks.first { $0.columns == ["total"] }?.shortLabel == "≥ 0")
        #expect(before.views["total"] == ["paid_\(suffix)"])
        #expect(before.size != nil)
        let primary = before.indexes.first { $0.name == "orders_\(suffix)_pkey" }
        #expect(primary?.constraint == true && primary?.method == "btree" && primary?.size != nil)

        let status = ColumnShape(before.columns.first { $0.name == "status" }!)
        var retyped = status
        retyped.name = "state"
        retyped.type = "varchar(20)"
        retyped.defaultValue = "'new'"
        let changes: [SchemaChange] = [
            .addColumn(ColumnShape(name: "gift_note", type: "text")),
            .alterColumn(old: status, new: retyped),
            .addIndex(IndexShape(name: "orders_\(suffix)_state_idx", columns: ["state", "created_at"])),
        ]
        let statements = try changes.flatMap { try RowChange(table: orders, key: [], kind: .schema($0)).statements(dialect: .postgres) }
        #expect(statements.count == 4)
        _ = try await using(readOnly: false) { try await $0.apply(statements, timeout: .seconds(10)) }
        let after = try await using(readOnly: true) { try await $0.describe(table: orders.path) }
        let state = after.columns.first { $0.name == "state" }
        #expect(state?.type == "character varying(20)" && state?.defaultValue?.hasPrefix("'new'") == true)
        #expect(after.columns.last?.name == "gift_note")
        #expect(after.indexes.first { $0.name == "orders_\(suffix)_state_idx" }?.columns == ["state", "created_at"])

        // A batch that fails leaves everything as it was.
        let failing = [SchemaChange.dropColumn(ColumnShape(name: "gift_note", type: "text")), .dropColumn(ColumnShape(name: "missing", type: "text"))]
        let failingStatements = try failing.flatMap { try RowChange(table: orders, key: [], kind: .schema($0)).statements(dialect: .postgres) }
        await #expect(throws: (any Error).self) {
            _ = try await using(readOnly: false) { try await $0.apply(failingStatements, timeout: .seconds(10)) }
        }
        let unchanged = try await using(readOnly: true) { try await $0.describe(table: orders.path) }
        #expect(unchanged.columns.contains { $0.name == "gift_note" })
        try await cleanup()
    }
}
