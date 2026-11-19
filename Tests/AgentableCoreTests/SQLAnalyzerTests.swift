import Testing
@testable import AgentableCore

@Suite struct SQLAnalyzerTests {
    func kinds(_ sql: String, _ dialect: SQLDialect = .postgres) -> [StatementKind] {
        SQLAnalyzer.statements(in: sql, dialect: dialect).map(\.kind)
    }

    @Test func splitsOnTopLevelSemicolonsOnly() {
        let sql = """
            SELECT 'a;b', "we;ird", $body$ ; $body$, E'it\\'s;' FROM t; -- comment ; here
            /* block ; /* nested ; */ */ UPDATE t SET x = 1;
            """
        let statements = SQLAnalyzer.statements(in: sql, dialect: .postgres)
        #expect(statements.count == 2)
        #expect(statements[0].verb == "SELECT")
        #expect(statements[1].verb == "UPDATE")
    }

    @Test func commentOnlyInputHasNoStatements() {
        #expect(SQLAnalyzer.statements(in: "-- nothing\n/* here */ ;", dialect: .sqlite).isEmpty)
    }

    @Test func catchesTheClassicReadOnlyBypass() {
        #expect(kinds("COMMIT; DROP TABLE users") == [.transaction, .schema])
    }

    @Test func classifiesReads() {
        #expect(kinds("SELECT * FROM orders") == [.read])
        #expect(kinds("(SELECT 1)") == [.read])
        #expect(kinds("WITH x AS (SELECT 1) SELECT * FROM x") == [.read])
        #expect(kinds("EXPLAIN DELETE FROM orders") == [.read])
        #expect(kinds("SHOW search_path") == [.read])
        #expect(kinds("PRAGMA table_info(orders)", .sqlite) == [.read])
    }

    @Test func classifiesWritesHiddenInsideReads() {
        #expect(kinds("WITH gone AS (DELETE FROM orders RETURNING id) SELECT * FROM gone") == [.write])
        #expect(kinds("SELECT * FROM orders FOR UPDATE") == [.write])
        #expect(kinds("SELECT * INTO backup FROM orders") == [.schema])
        #expect(kinds("EXPLAIN ANALYZE DELETE FROM orders") == [.write])
        #expect(kinds("EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET x = 1") == [.write])
        #expect(kinds("EXPLAIN (ANALYZE false) UPDATE t SET x = 1") == [.read])
        #expect(kinds("PRAGMA journal_mode = DELETE", .sqlite) == [.session])
    }

    @Test func classifiesOtherStatements() {
        #expect(kinds("INSERT INTO t VALUES (1)") == [.write])
        #expect(kinds("ALTER TABLE t ADD COLUMN x int") == [.schema])
        #expect(kinds("TRUNCATE t") == [.schema])
        #expect(kinds("SET statement_timeout = 0") == [.session])
        #expect(kinds("BEGIN") == [.transaction])
        #expect(kinds("DO $$ BEGIN PERFORM 1; END $$") == [.write])
    }

    @Test func keepsTriggerBodiesTogether() {
        let sql = """
            CREATE TRIGGER audit AFTER UPDATE ON t BEGIN
              INSERT INTO log VALUES (CASE WHEN new.x > 1 THEN 'big' ELSE 'small' END);
              UPDATE t SET touched = 1;
            END;
            SELECT 1;
            """
        #expect(kinds(sql, .sqlite) == [.schema, .read])
    }

    @Test func collectsIdentifiers() {
        let statement = SQLAnalyzer.statements(in: "SELECT \"Email\" FROM api_keys", dialect: .postgres)[0]
        #expect(statement.identifiers.contains("api_keys"))
        #expect(statement.identifiers.contains("email"))
    }
}
