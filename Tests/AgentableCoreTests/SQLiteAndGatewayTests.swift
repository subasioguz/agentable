import Foundation
import Testing
@testable import AgentableCore

/// A temporary Agentable home with one SQLite database of orders and customers.
struct Fixture {
    let root: URL
    let databasePath: String
    let gateway: AgentGateway

    init(environment: DeploymentEnvironment, access: AgentAccess? = nil, rules: VisibilityRules = .init()) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "agentable-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databasePath = root.appending(path: "shop.sqlite").path

        let setup = try SQLiteSession(path: databasePath, mode: .create)
        _ = try await setup.apply([
            "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT)",
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), status TEXT NOT NULL DEFAULT 'pending', total REAL)",
            "CREATE TABLE api_keys (id INTEGER PRIMARY KEY, secret TEXT)",
            "INSERT INTO customers VALUES (1, 'Mara', 'mara@northwind.com'), (2, 'Kenji', 'kenji@kestrel.io')",
            "INSERT INTO orders VALUES (1, 1, 'paid', 129.0), (2, 2, 'paid', 64.5), (3, 1, 'shipped', 312.9)",
        ], timeout: .seconds(5))

        let profiles = ProfileStore(file: root.appending(path: "connections.json"))
        try profiles.add(ConnectionProfile(
            name: "shop", engine: .sqlite, environment: environment, database: databasePath, agentAccess: access, rules: rules
        ))
        gateway = AgentGateway(
            profiles: profiles,
            secrets: InMemorySecretStore(),
            state: try StateStore(url: root.appending(path: "state.sqlite")),
            sessions: DefaultSessionFactory()
        )
    }
}

struct AlwaysConfirm: Authenticator {
    func authenticate(reason: String) async throws {}
}

struct NeverConfirm: Authenticator {
    func authenticate(reason: String) async throws { throw AuthenticationError.declined }
}

@Suite struct SQLiteSessionTests {
    @Test func readOnlySessionsRefuseWrites() async throws {
        let fixture = try await Fixture(environment: .local)
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        await #expect(throws: DatabaseError.readOnlyViolation) {
            try await session.run("UPDATE orders SET total = 0", options: QueryOptions(readOnly: true, maxRows: 10, timeout: .seconds(2)))
        }
    }

    @Test func rowLimitTruncates() async throws {
        let fixture = try await Fixture(environment: .local)
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let result = try await session.run("SELECT * FROM orders", options: QueryOptions(readOnly: true, maxRows: 2, timeout: .seconds(2)))
        #expect(result.rows.count == 2)
        #expect(result.truncated)
        #expect(result.columns.map(\.sourceTable) == ["orders", "orders", "orders", "orders"])
    }

    @Test func runawayQueriesTimeOut() async throws {
        let fixture = try await Fixture(environment: .local)
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let forever = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT count(*) FROM n"
        await #expect(throws: DatabaseError.self) {
            try await session.run(forever, options: QueryOptions(readOnly: true, maxRows: 10, timeout: .milliseconds(200)))
        }
    }

    @Test func describesTables() async throws {
        let fixture = try await Fixture(environment: .local)
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let orders = try await session.describe(table: "ORDERS")
        #expect(orders.columns.map(\.name) == ["id", "customer_id", "status", "total"])
        #expect(orders.columns[0].primaryKey)
        #expect(orders.foreignKeys.first?.referencedTable == "customers")
    }
}

@Suite struct GatewayTests {
    @Test func readsAreMaskedAndLogged() async throws {
        let fixture = try await Fixture(environment: .production, rules: VisibilityRules(maskedColumns: ["customers.email"]))
        guard case .result(let outcome) = try await fixture.gateway.query(
            connection: "shop", sql: "SELECT name, email AS contact FROM customers ORDER BY id", client: "test-agent"
        ) else {
            Issue.record("expected rows")
            return
        }
        #expect(outcome.readOnly)
        #expect(outcome.maskedColumns == ["contact"])
        #expect(outcome.result.rows[0] == [.text("Mara"), .text("m•••@n•••.com")])
        let text = AgentFormatter.text(outcome)
        #expect(text.contains("not instructions"))
        #expect(text.contains("masked: contact"))
        let events = try await fixture.gateway.state.events(connection: "shop")
        #expect(events.first?.action == .read)
        #expect(events.first?.client == "test-agent")
    }

    @Test func productionWritesAreDenied() async throws {
        let fixture = try await Fixture(environment: .production)
        guard case .denied = try await fixture.gateway.query(connection: "shop", sql: "DELETE FROM orders", client: "a") else {
            Issue.record("expected deny")
            return
        }
        let count = try await fixture.gateway.query(connection: "shop", sql: "SELECT count(*) FROM orders", client: "a")
        guard case .result(let outcome) = count else { return }
        #expect(outcome.result.rows[0][0] == .integer(3))
    }

    @Test func hiddenTablesDisappear() async throws {
        let fixture = try await Fixture(environment: .local, rules: VisibilityRules(hiddenTables: ["api_keys"]))
        let tables = try await fixture.gateway.tables(connection: "shop")
        #expect(!tables.map(\.name).contains("api_keys"))
        let matches = try await fixture.gateway.searchSchema(connection: "shop", text: "secret")
        #expect(matches.isEmpty)
    }

    @Test func proposalsWaitForAPerson() async throws {
        let fixture = try await Fixture(environment: .production, access: .propose)
        guard case .proposed(let proposal) = try await fixture.gateway.query(
            connection: "shop", sql: "UPDATE orders SET status = 'refund_pending' WHERE status = 'paid'", client: "agent"
        ) else {
            Issue.record("expected a proposal")
            return
        }
        #expect(proposal.dryRunRows == 2)

        // The trial run was rolled back.
        let session = try SQLiteSession(path: fixture.databasePath, mode: .readOnly)
        let paid = try await session.run("SELECT count(*) FROM orders WHERE status = 'paid'", options: QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(2)))
        #expect(paid.rows[0][0] == .integer(2))

        // Without confirmation nothing happens.
        let refused = ReviewService(gateway: fixture.gateway, authenticator: NeverConfirm())
        await #expect(throws: AuthenticationError.self) { try await refused.approve(proposal.id) }

        let review = ReviewService(gateway: fixture.gateway, authenticator: AlwaysConfirm())
        let applied = try await review.approve(proposal.id)
        #expect(applied.status == .applied)
        let after = try await session.run("SELECT count(*) FROM orders WHERE status = 'refund_pending'", options: QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(2)))
        #expect(after.rows[0][0] == .integer(2))
        await #expect(throws: ProposalError.notPending(proposal.id, .applied)) { try await review.reject(proposal.id, note: nil) }
    }

    @Test func brokenProposalsAreNotFiled() async throws {
        let fixture = try await Fixture(environment: .staging)
        await #expect(throws: ProposalError.self) {
            try await fixture.gateway.propose(connection: "shop", sql: "UPDATE nope SET x = 1", reason: nil, client: "a")
        }
        #expect(try await fixture.gateway.state.proposals().isEmpty)
    }
}
