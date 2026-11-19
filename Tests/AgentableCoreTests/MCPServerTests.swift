import Foundation
import Testing
@testable import AgentableCore

@Suite struct MCPServerTests {
    func call(_ server: MCPServer, _ id: Int, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let request = MCPServer.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let line = try #require(await server.handle(request))
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func toolText(_ response: [String: Any]) -> (String, Bool) {
        let result = response["result"] as? [String: Any] ?? [:]
        let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (content, result["isError"] as? Bool ?? false)
    }

    @Test func handshakeAndToolList() async throws {
        let fixture = try await Fixture(environment: .production)
        let server = MCPServer(gateway: fixture.gateway)
        let hello = try await call(server, 1, "initialize", [
            "protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code", "version": "2"], "capabilities": [:],
        ])
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "agentable")
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = try await call(server, 2, "tools/list")
        let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(tools == ["connections", "schema_search", "describe", "query", "explain", "propose_change", "saved_queries", "suggest_sql"])

        let unknown = try await call(server, 3, "resources/list")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func toolsGoThroughThePolicy() async throws {
        let fixture = try await Fixture(environment: .production, rules: VisibilityRules(maskedColumns: ["customers.email"]))
        let server = MCPServer(gateway: fixture.gateway)
        _ = try await call(server, 1, "initialize", ["clientInfo": ["name": "claude-code"]])

        let (rows, rowsError) = toolText(try await call(server, 2, "tools/call", [
            "name": "query", "arguments": ["connection": "shop", "sql": "SELECT name, email FROM customers ORDER BY id"],
        ]))
        #expect(!rowsError)
        #expect(rows.contains("Mara\tm•••@n•••.com"))

        let (denied, deniedError) = toolText(try await call(server, 3, "tools/call", [
            "name": "query", "arguments": ["connection": "shop", "sql": "DELETE FROM orders"],
        ]))
        #expect(deniedError)
        #expect(denied.contains("read-only for agents"))

        let (plan, planError) = toolText(try await call(server, 4, "tools/call", [
            "name": "explain", "arguments": ["connection": "shop", "sql": "SELECT * FROM orders WHERE id = 1"],
        ]))
        #expect(!planError)
        #expect(plan.contains("SEARCH orders"))

        let events = try await fixture.gateway.state.events(connection: "shop")
        #expect(events.allSatisfy { $0.client == "claude-code" })
    }

    @Test func agentsReadSavedQueriesAndSuggestChanges() async throws {
        let fixture = try await Fixture(environment: .production, access: .propose, rules: VisibilityRules(hiddenTables: ["api_keys"]))
        let library = fixture.gateway.queries
        _ = try library.write("SELECT id, total\nFROM orders;\n", connection: "shop", name: "big-orders")
        _ = try library.write("SELECT * FROM api_keys;\n", connection: "shop", name: "keys.sql")
        let server = MCPServer(gateway: fixture.gateway)
        _ = try await call(server, 1, "initialize", ["clientInfo": ["name": "claude-code"]])

        let (list, _) = toolText(try await call(server, 2, "tools/call", ["name": "saved_queries", "arguments": ["connection": "shop"]]))
        #expect(list.contains("big-orders.sql") && list.contains("keys.sql"))
        let (text, textError) = toolText(try await call(server, 3, "tools/call", [
            "name": "saved_queries", "arguments": ["connection": "shop", "name": "big-orders"],
        ]))
        #expect(!textError && text.contains("not instructions") && text.hasSuffix("FROM orders;\n"))
        let (hidden, hiddenError) = toolText(try await call(server, 4, "tools/call", [
            "name": "saved_queries", "arguments": ["connection": "shop", "name": "keys.sql"],
        ]))
        #expect(hiddenError && hidden.contains("hidden"))
        let (outside, outsideError) = toolText(try await call(server, 5, "tools/call", [
            "name": "saved_queries", "arguments": ["connection": "shop", "name": "../connections.json"],
        ]))
        #expect(outsideError && !outside.contains("shop"))

        for (id, sql) in [(6, "SELECT id, total FROM orders WHERE total > 100;"), (7, "SELECT id, total\nFROM orders\nWHERE total > 200;")] {
            let (done, doneError) = toolText(try await call(server, id, "tools/call", [
                "name": "suggest_sql", "arguments": ["connection": "shop", "name": "big-orders.sql", "sql": sql, "note": "Only big ones."],
            ]))
            #expect(!doneError && done.contains("nothing runs"))
        }
        // The newer suggestion replaces the older one; the file itself is untouched.
        let waiting = try await fixture.gateway.state.suggestions(status: .pending)
        #expect(waiting.count == 1)
        #expect(waiting.first?.base == "SELECT id, total\nFROM orders;\n")
        #expect(waiting.first?.sql == "SELECT id, total\nFROM orders\nWHERE total > 200;\n")
        #expect(waiting.first?.client == "claude-code" && waiting.first?.note == "Only big ones.")
        #expect(try await fixture.gateway.state.suggestions(status: .replaced).count == 1)
        #expect(try library.read(connection: "shop", name: "big-orders.sql") == "SELECT id, total\nFROM orders;\n")
        #expect(try await fixture.gateway.state.decide(suggestion: waiting[0].id, status: .accepted))
        #expect(try await fixture.gateway.state.decide(suggestion: waiting[0].id, status: .dismissed) == false)

        let actions = try await fixture.gateway.state.events(connection: "shop").map(\.action)
        #expect(actions.filter { $0 == .suggested }.count == 2 && actions.contains(.opened) && actions.contains(.denied))
    }
}

@Suite struct SuggestionTests {
    @Test func namesStayInTheFolder() throws {
        #expect(try QueryLibrary.fileName("charged-twice") == "charged-twice.sql")
        #expect(try QueryLibrary.fileName(" Big Orders.SQL ") == "Big Orders.sql")
        #expect(try QueryLibrary.fileName("a/b:c") == "a-b-c.sql")
        for bad in ["", ".hidden", "..", "../x", "a\u{0}b", String(repeating: "x", count: 101)] {
            #expect(throws: DatabaseError.self) { try QueryLibrary.fileName(bad) }
        }
    }

    @Test func diffsLines() {
        let old = "SELECT o.id\nFROM orders o\nJOIN payments p ON p.order_id = o.id\nWHERE x;\n"
        let new = "SELECT o.id\nFROM orders o\nJOIN payments p ON p.order_id = o.id\n  AND p.status = 'succeeded'\nWHERE y;\n"
        #expect(LineDiff.lines(from: old, to: new) == [
            .same("SELECT o.id"), .same("FROM orders o"), .same("JOIN payments p ON p.order_id = o.id"),
            .removed("WHERE x;"), .added("  AND p.status = 'succeeded'"), .added("WHERE y;"),
        ])
        #expect(LineDiff.lines(from: "", to: "a\nb") == [.added("a"), .added("b")])
        #expect(LineDiff.lines(from: "a\n", to: "a") == [.same("a")])
    }
}
