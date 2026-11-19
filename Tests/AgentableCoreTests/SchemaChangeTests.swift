import Foundation
import Testing
@testable import AgentableCore

@Suite struct SchemaChangeTests {
    let orders = TableRef(schema: "public", name: "orders")
    let status = ColumnShape(name: "status", type: "text", nullable: false, defaultValue: "'pending'::text")

    func sql(_ change: SchemaChange, _ dialect: SQLDialect = .postgres) throws -> [String] {
        try change.statements(table: orders, dialect: dialect)
    }

    @Test func addsColumnsWithDefaultsAndEmptyValues() throws {
        #expect(try sql(.addColumn(ColumnShape(name: "gift_note", type: "text"))) == [
            #"ALTER TABLE "public"."orders" ADD COLUMN "gift_note" text"#,
        ])
        #expect(try sql(.addColumn(ColumnShape(name: "channel", type: "varchar(20)", nullable: false, defaultValue: "'web'"))) == [
            #"ALTER TABLE "public"."orders" ADD COLUMN "channel" varchar(20) DEFAULT 'web' NOT NULL"#,
        ])
    }

    @Test func renamingAndChangingAColumnTakesTwoStatements() throws {
        var new = status
        new.name = "state"
        new.type = "varchar(20)"
        new.nullable = true
        new.defaultValue = "'new'"
        #expect(try sql(.alterColumn(old: status, new: new)) == [
            #"ALTER TABLE "public"."orders" RENAME COLUMN "status" TO "state""#,
            #"ALTER TABLE "public"."orders" ALTER COLUMN "state" DROP DEFAULT, ALTER COLUMN "state" TYPE varchar(20) USING "state"::varchar(20), ALTER COLUMN "state" SET DEFAULT 'new', ALTER COLUMN "state" DROP NOT NULL"#,
        ])
        var renamed = status
        renamed.name = "state"
        #expect(SchemaChange.alterColumn(old: status, new: renamed).title == "Rename column status to state")
        var noDefault = status
        noDefault.defaultValue = nil
        #expect(try sql(.alterColumn(old: status, new: noDefault)) == [#"ALTER TABLE "public"."orders" ALTER COLUMN "status" DROP DEFAULT"#])
    }

    @Test func indexesAndDrops() throws {
        #expect(try sql(.addIndex(IndexShape(name: "orders_status_created_at_idx", columns: ["status", "created_at"]))) == [
            #"CREATE INDEX "orders_status_created_at_idx" ON "public"."orders" ("status", "created_at")"#,
        ])
        #expect(try sql(.addIndex(IndexShape(name: "orders_number_key", columns: ["number"], unique: true)), .sqlite).first?.hasPrefix("CREATE UNIQUE INDEX") == true)
        #expect(try sql(.dropIndex(IndexShape(name: "old_idx", columns: []))) == [#"DROP INDEX "public"."old_idx""#])
        #expect(try sql(.dropColumn(status)) == [#"ALTER TABLE "public"."orders" DROP COLUMN "status""#])
        #expect(IndexShape.suggestedName(table: "orders", columns: ["status", "created_at DESC"], unique: false) == "orders_status_created_at_idx")
    }

    @Test func sqliteOnlyRenamesInPlace() throws {
        var retyped = status
        retyped.type = "integer"
        #expect(SchemaChange.alterColumn(old: status, new: retyped).problem(dialect: .sqlite) != nil)
        #expect(throws: DatabaseError.self) { try sql(.alterColumn(old: status, new: retyped), .sqlite) }
        var renamed = status
        renamed.name = "state"
        #expect(SchemaChange.alterColumn(old: status, new: renamed).problem(dialect: .sqlite) == nil)
        #expect(SchemaChange.addColumn(ColumnShape(name: "a", type: "text", nullable: false)).problem(dialect: .sqlite) != nil)
        #expect(SchemaChange.addColumn(ColumnShape(name: "a", type: "text", nullable: false, defaultValue: "''")).problem(dialect: .sqlite) == nil)
    }

    @Test func typesAreTypeNamesOnly() {
        for good in ["text", "numeric(10,2)", "numeric(10, 2)", "timestamp(3) with time zone", "varchar(80)[]", "public.order_status", "\"Mood\"", "double precision"] {
            #expect(SchemaChange.typeProblem(good) == nil, "\(good)")
        }
        for bad in ["", "text; DROP TABLE orders", "int) --", "numeric(1+1)", "text DEFAULT 'x'", "(int)", "int(", "text /* x */"] {
            #expect(SchemaChange.typeProblem(bad) != nil, "\(bad)")
        }
    }

    @Test func defaultsAreOneExpression() {
        for good in ["'pending'", "now()", "0", "'a;b -- c'", "(1 + 2)", "gen_random_uuid()"] {
            #expect(SchemaChange.defaultProblem(good, dialect: .postgres) == nil, "\(good)")
        }
        for bad in ["1; DROP TABLE orders", "0 -- x", "0 /* x */", "(1", "1)", "  "] {
            #expect(SchemaChange.defaultProblem(bad, dialect: .postgres) != nil, "\(bad)")
        }
    }

    @Test func readsChecks() {
        let listed = CheckInfo(name: "orders_status_check", definition: CheckInfo.condition(
            "CHECK ((status = ANY (ARRAY['pending'::text, 'paid'::text, 'it''s'::text])))"
        ), columns: ["status"])
        #expect(listed.definition == "status = ANY (ARRAY['pending'::text, 'paid'::text, 'it''s'::text])")
        #expect(listed.allowedValues == ["pending", "paid", "it's"])
        #expect(listed.shortLabel == "3 values")
        #expect(CheckInfo(name: nil, definition: CheckInfo.condition("CHECK (total >= 0::numeric)"), columns: ["total"]).shortLabel == "≥ 0")
        #expect(CheckInfo(name: nil, definition: "a < b", columns: ["a", "b"]).shortLabel == nil)

        let parsed = CheckInfo.parse(createTable: """
            CREATE TABLE t (id integer PRIMARY KEY, status text CHECK (status IN ('a', 'b')), total real,
              CONSTRAINT positive CHECK ((total) >= 0))
            """, columns: ["id", "status", "total"])
        #expect(parsed.count == 2)
        #expect(parsed.first?.columns == ["status"])
        #expect(parsed.first?.allowedValues == ["a", "b"])
        #expect(parsed.last?.name == "positive")
        #expect(parsed.last?.columns == ["total"])
        #expect(parsed.last?.shortLabel == "≥ 0")
    }

    @Test func masksFollowRenamedColumns() async throws {
        let fixture = try await Fixture(environment: .production, access: .propose, rules: VisibilityRules(maskedColumns: ["customers.email"]))
        let review = ReviewService(gateway: fixture.gateway, authenticator: AlwaysConfirm())
        let rename = SchemaChange.alterColumn(old: ColumnShape(name: "email", type: "TEXT"), new: ColumnShape(name: "contact", type: "TEXT"))
        try await review.apply(connection: "shop", edits: [RowChange(table: TableRef(name: "customers"), key: [], kind: .schema(rename))], proposalIDs: [])
        #expect(try fixture.gateway.profiles.profile(named: "shop").rules.maskedColumns == ["customers.contact"])

        // The agent still sees the column masked under its new name.
        guard case .result(let outcome) = try await fixture.gateway.query(connection: "shop", sql: "SELECT contact FROM customers ORDER BY id", client: "test") else {
            Issue.record("expected rows")
            return
        }
        #expect(outcome.maskedColumns == ["contact"])
        #expect(outcome.result.rows.first?.first != .text("mara@northwind.com"))
    }

    @Test func sqliteAppliesStructureChangesThroughReview() async throws {
        let fixture = try await Fixture(environment: .local)
        let review = ReviewService(gateway: fixture.gateway, authenticator: AlwaysConfirm())
        let table = TableRef(name: "orders")
        let changes: [SchemaChange] = [
            .addColumn(ColumnShape(name: "gift_note", type: "text")),
            .alterColumn(old: ColumnShape(name: "total", type: "REAL"), new: ColumnShape(name: "amount", type: "REAL")),
            .addIndex(IndexShape(name: "orders_status_idx", columns: ["status"])),
        ]
        try await review.apply(connection: "shop", edits: changes.map { RowChange(table: table, key: [], kind: .schema($0)) }, proposalIDs: [])

        let reader = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let described = try await reader.describe(table: "orders")
        #expect(described.columns.map(\.name) == ["id", "customer_id", "status", "amount", "gift_note"])
        #expect(described.indexes.contains { $0.name == "orders_status_idx" && !$0.constraint })

        // A batch that fails changes nothing.
        let bad: [SchemaChange] = [.dropIndex(IndexShape(name: "orders_status_idx", columns: [])), .dropColumn(ColumnShape(name: "missing", type: "text"))]
        await #expect(throws: (any Error).self) {
            try await review.apply(connection: "shop", edits: bad.map { RowChange(table: table, key: [], kind: .schema($0)) }, proposalIDs: [])
        }
        let after = try await reader.describe(table: "orders")
        #expect(after.indexes.contains { $0.name == "orders_status_idx" })

        let writer = try SQLiteSession(path: fixture.databasePath, mode: .readWrite)
        _ = try await writer.apply(["CREATE INDEX orders_amount_desc ON orders (amount DESC, status)"], timeout: .seconds(5))
        #expect(try await reader.describe(table: "orders").indexes.first { $0.name == "orders_amount_desc" }?.columns == ["amount DESC", "status"])

        let events = try await fixture.gateway.state.events(connection: "shop", limit: 10)
        #expect(events.contains { $0.sql.hasPrefix(#"ALTER TABLE "orders" RENAME COLUMN "total" TO "amount""#) && $0.rows == nil })
    }
}

@Suite struct ProposedIndexTests {
    @Test func readsCreateIndexStatements() {
        let plain = ProposedIndex.parse("CREATE INDEX orders_status_created_idx ON orders (status, created_at DESC)", dialect: .postgres)
        #expect(plain?.table == TableRef(name: "orders"))
        #expect(plain?.index == IndexShape(name: "orders_status_created_idx", columns: ["status", "created_at DESC"]))
        #expect(plain?.concurrently == false)

        let full = ProposedIndex.parse(#"create unique index concurrently if not exists "Idx" on only public."Orders" using btree (lower(email), "Id")"#, dialect: .postgres)
        #expect(full?.table == TableRef(schema: "public", name: "Orders"))
        #expect(full?.index == IndexShape(name: "Idx", columns: ["lower(email)", "Id"], unique: true))
        #expect(full?.method == "btree" && full?.concurrently == true)

        #expect(ProposedIndex.parse("UPDATE orders SET a = 1", dialect: .postgres) == nil)
        #expect(ProposedIndex.parse("CREATE INDEX x ON orders", dialect: .postgres) == nil)
    }
}
