import Testing
@testable import AgentableCore

@Suite struct PolicyTests {
    func profile(_ environment: DeploymentEnvironment, access: AgentAccess? = nil, rules: VisibilityRules = .init()) -> ConnectionProfile {
        ConnectionProfile(name: "db", engine: .sqlite, environment: environment, database: "/tmp/x.db", agentAccess: access, rules: rules)
    }

    @Test func environmentDefaultsAndCaps() {
        #expect(profile(.production).effectiveAgentAccess == .read)
        #expect(profile(.staging).effectiveAgentAccess == .propose)
        #expect(profile(.local).effectiveAgentAccess == .write)
        #expect(profile(.production, access: .write).effectiveAgentAccess == .propose)
    }

    @Test func readsRunReadOnly() {
        guard case .run(_, let readOnly) = AgentPolicy.evaluate("SELECT 1", on: profile(.production)) else {
            Issue.record("expected run")
            return
        }
        #expect(readOnly)
    }

    @Test func writesFollowTheAccessLevel() {
        if case .deny = AgentPolicy.evaluate("DELETE FROM t", on: profile(.production)) {} else { Issue.record("read should deny writes") }
        if case .propose = AgentPolicy.evaluate("DELETE FROM t", on: profile(.staging)) {} else { Issue.record("propose expected") }
        if case .propose = AgentPolicy.evaluate("DELETE FROM t", on: profile(.production, access: .write)) {} else {
            Issue.record("production must cap at propose")
        }
        guard case .run(_, let readOnly) = AgentPolicy.evaluate("DELETE FROM t", on: profile(.local)) else {
            Issue.record("local write expected")
            return
        }
        #expect(!readOnly)
    }

    @Test func refusesWhatAgentsShouldNotSend() {
        let local = profile(.local)
        for sql in ["SELECT 1; SELECT 2", "COMMIT; DROP TABLE t", "BEGIN", "SET role postgres", ""] {
            if case .deny = AgentPolicy.evaluate(sql, on: local) {} else { Issue.record("expected deny for \(sql)") }
        }
        if case .deny = AgentPolicy.evaluate("SELECT 1", on: profile(.local, access: .off)) {} else { Issue.record("off denies") }
    }

    @Test func hiddenTablesAreRefused() {
        let rules = VisibilityRules(hiddenTables: ["public.api_keys"])
        guard case .deny(let message) = AgentPolicy.evaluate("SELECT * FROM API_KEYS", on: profile(.local, rules: rules)) else {
            Issue.record("expected deny")
            return
        }
        #expect(message.contains("api_keys"))
    }

    @Test func masksByOriginAndByMention() {
        let rules = VisibilityRules(maskedColumns: ["customers.email"])
        let direct = [ResultColumn(name: "e", sourceTable: "customers", sourceColumn: "email"), ResultColumn(name: "id", sourceTable: "customers", sourceColumn: "id")]
        #expect(Masking.columnsToMask(direct, rules: rules, mentioned: []) == [0])
        let computed = [ResultColumn(name: "lower(email)")]
        #expect(Masking.columnsToMask(computed, rules: rules, mentioned: ["email", "customers"]) == [0])
    }

    @Test func maskedValuesKeepTheirShape() {
        #expect(Masking.maskText("jane@northwind.com") == "j•••@n•••.com")
        #expect(Masking.maskText("+1 415 555 0193") == "+• ••• ••• 0193")
        #expect(Masking.maskText("Acme") == "A•••")
    }

    @Test func parsesConnectionURLs() throws {
        let pg = try ConnectionURL.parse("postgres://app:s%40cret@db.internal:6543/acme?sslmode=require", name: "acme", environment: .production)
        #expect(pg.profile.engine == .postgres)
        #expect(pg.profile.host == "db.internal")
        #expect(pg.profile.port == 6543)
        #expect(pg.profile.user == "app")
        #expect(pg.profile.database == "acme")
        #expect(pg.profile.tls == .require)
        #expect(pg.password == "s@cret")
        #expect(pg.profile.location == "app@db.internal:6543/acme")

        let file = try ConnectionURL.parse("/tmp/metrics.sqlite", name: "m", environment: .local)
        #expect(file.profile.engine == .sqlite)
        #expect(file.profile.database == "/tmp/metrics.sqlite")
        #expect(throws: ConnectionURLError.unsupportedScheme("mongodb")) {
            try ConnectionURL.parse("mongodb://x", name: "m", environment: .local)
        }
    }

    @Test func validatesNames() {
        #expect(ConnectionProfile.isValidName("acme-prod.eu_1"))
        #expect(!ConnectionProfile.isValidName("Acme"))
        #expect(!ConnectionProfile.isValidName("-x"))
        #expect(!ConnectionProfile.isValidName("a b"))
    }

    @Test func agentRoleGrantsOnlyVisibleTables() {
        let sql = AgentRole.setupSQL(
            role: "agent_ro",
            database: "acme",
            tables: [TableSummary(schema: "public", name: "orders", kind: .table), TableSummary(schema: "public", name: "api_keys", kind: .table)],
            rules: VisibilityRules(hiddenTables: ["api_keys"])
        )
        #expect(sql.contains(#"GRANT SELECT ON "public"."orders" TO "agent_ro";"#))
        #expect(!sql.contains(#"ON "public"."api_keys""#))
        #expect(sql.contains("default_transaction_read_only = on"))
    }
}
