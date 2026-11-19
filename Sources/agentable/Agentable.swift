import ArgumentParser
import Foundation
import AgentableCore

@main
struct Agentable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentable",
        abstract: "A database client for you and your coding agents.",
        discussion: """
            Agents use query, tables, describe, search, propose, queries and suggest. They address connections by name \
            and never see passwords. Writes on protected connections become proposals that a person \
            reviews with `agentable review`.
            """,
        subcommands: [
            Connections.self, Tables.self, Describe.self, Search.self, Query.self,
            Propose.self, Proposals.self, Review.self, Queries.self, Suggest.self, Log.self, MCP.self, Init.self,
        ]
    )
}

/// Everything a command needs, wired to the real stores.
struct Context {
    let paths: AgentablePaths
    let profiles: ProfileStore
    let secrets: any SecretStore
    let gateway: AgentGateway
    let review: ReviewService

    static func make() throws -> Context {
        let paths = AgentablePaths.standard()
        try paths.ensureExists()
        let profiles = ProfileStore(file: paths.connectionsFile)
        let secrets = KeychainSecretStore()
        let gateway = AgentGateway(
            profiles: profiles,
            secrets: secrets,
            state: try StateStore(url: paths.stateDatabase),
            sessions: DefaultSessionFactory()
        )
        return Context(
            paths: paths,
            profiles: profiles,
            secrets: secrets,
            gateway: gateway,
            review: ReviewService(gateway: gateway, authenticator: DeviceOwnerAuthenticator())
        )
    }
}

struct ClientOption: ParsableArguments {
    @Option(help: "Who is asking, for the audit log (defaults to $AGENTABLE_CLIENT or \"cli\").")
    var client: String?

    var name: String {
        client ?? ProcessInfo.processInfo.environment["AGENTABLE_CLIENT"] ?? "cli"
    }
}

/// Denied requests exit with 2 so scripts and agents can tell them from errors.
func printDenied(_ message: String) throws -> Never {
    print("-- denied: \(message)")
    throw ExitCode(2)
}

func printStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

extension AgentAccess: ExpressibleByArgument {}
extension DeploymentEnvironment: ExpressibleByArgument {}

// MARK: - Agent commands

struct Query: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run one SQL statement on a connection.")

    @Argument(help: "Connection name.") var connection: String
    @Argument(help: "One SQL statement.") var sql: String
    @Flag(help: "Print JSON instead of tab-separated text.") var json = false
    @OptionGroup var client: ClientOption

    func run() async throws {
        let context = try Context.make()
        switch try await context.gateway.query(connection: connection, sql: sql, client: client.name) {
        case .result(let result):
            print(json ? try AgentFormatter.json(result) : AgentFormatter.text(result))
        case .proposed(let proposal):
            print(json ? try AgentFormatter.json(proposal) : AgentFormatter.text(proposal))
        case .denied(let message):
            try printDenied(message)
        }
    }
}

struct Propose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "File a change for a person to review.")

    @Argument(help: "Connection name.") var connection: String
    @Argument(help: "One statement that changes data or schema.") var sql: String
    @Option(help: "Why, in a sentence the reviewer will read.") var reason: String?
    @Flag var json = false
    @OptionGroup var client: ClientOption

    func run() async throws {
        let context = try Context.make()
        switch try await context.gateway.propose(connection: connection, sql: sql, reason: reason, client: client.name) {
        case .proposed(let proposal):
            print(json ? try AgentFormatter.json(proposal) : AgentFormatter.text(proposal))
        case .denied(let message):
            try printDenied(message)
        case .result:
            break
        }
    }
}

struct Queries: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the person's saved queries, or print one.")

    @Argument(help: "Connection name.") var connection: String
    @Argument(help: "A query's file name, like charged-twice.sql.") var name: String?
    @OptionGroup var client: ClientOption

    func run() async throws {
        let gateway = try Context.make().gateway
        if let name {
            let text = try await gateway.savedQuery(connection: connection, query: name, client: client.name)
            print(AgentFormatter.text(savedQuery: text, name: try QueryLibrary.fileName(name), connection: connection))
        } else {
            let files = try await gateway.savedQueries(connection: connection, client: client.name)
            print(AgentFormatter.text(savedQueries: files, connection: connection))
        }
    }
}

struct Suggest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Suggest new text for a saved query; the person accepts or dismisses it in the SQL tab."
    )

    @Argument(help: "Connection name.") var connection: String
    @Argument(help: "The query's file name; a new name makes a new query.") var name: String
    @Argument(help: "The whole new text of the query, or - to read it from standard input.") var sql: String
    @Option(help: "Why, in one or two sentences.") var note: String?
    @OptionGroup var client: ClientOption

    func run() async throws {
        let text = sql == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : sql
        let suggestion = try await Context.make().gateway.suggest(connection: connection, query: name, sql: text, note: note, client: client.name)
        print(AgentFormatter.text(suggestion))
    }
}

struct Tables: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List tables and views.")

    @Argument var connection: String
    @Flag var json = false

    func run() async throws {
        let tables = try await Context.make().gateway.tables(connection: connection)
        print(json ? try AgentFormatter.json(tables) : AgentFormatter.text(tables: tables, connection: connection))
    }
}

struct Describe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Columns, keys and indexes of a table.")

    @Argument var connection: String
    @Argument var table: String
    @Flag var json = false

    func run() async throws {
        let context = try Context.make()
        let description = try await context.gateway.describe(connection: connection, table: table)
        let rules = try context.profiles.profile(named: connection).rules
        print(json ? try AgentFormatter.json(description) : AgentFormatter.text(description, rules: rules))
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find tables and columns by name.")

    @Argument var connection: String
    @Argument var text: String
    @Flag var json = false

    func run() async throws {
        let matches = try await Context.make().gateway.searchSchema(connection: connection, text: text)
        print(json ? try AgentFormatter.json(matches) : AgentFormatter.text(matches: matches, connection: connection, query: text))
    }
}

// MARK: - Review (people)

struct Proposals: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List proposed changes.")

    @Flag(help: "Include decided proposals.") var all = false
    @Flag var json = false

    func run() async throws {
        let state = try Context.make().gateway.state
        let proposals = try await state.proposals(status: all ? nil : .pending)
        if json {
            print(try AgentFormatter.json(proposals))
            return
        }
        guard !proposals.isEmpty else {
            print(all ? "No proposals yet." : "Nothing waiting for review.")
            return
        }
        for proposal in proposals {
            let rows = proposal.dryRunRows.map { " · trial run: \($0) rows" } ?? ""
            print("\(proposal.id)  \(proposal.status.rawValue)  \(proposal.connection)  from \(proposal.client)\(rows)")
            if let reason = proposal.reason { print("  why: \(reason)") }
            print("  \(proposal.sql)")
            if let result = proposal.result { print("  result: \(result)") }
        }
    }
}

struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Approve or reject a proposal. Approving asks for Touch ID or your password."
    )

    @Argument var id: String
    @Flag(help: "Apply the change.") var approve = false
    @Flag(help: "Discard the change.") var reject = false
    @Option(help: "A note for the agent when rejecting.") var note: String?

    func validate() throws {
        guard approve != reject else { throw ValidationError("Pass exactly one of --approve or --reject.") }
    }

    func run() async throws {
        let review = try Context.make().review
        let decided = approve ? try await review.approve(id) : try await review.reject(id, note: note)
        print("\(decided.id): \(decided.status.rawValue)\(decided.result.map { " · \($0)" } ?? "")")
    }
}

struct Log: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What agents and people did, newest first.")

    @Argument var connection: String?
    @Option var limit = 30

    func run() async throws {
        let events = try await Context.make().gateway.state.events(connection: connection, limit: limit)
        let time = Date.FormatStyle(date: .numeric, time: .standard)
        for event in events {
            let rows = event.rows.map { " · \($0) rows" } ?? ""
            print("\(event.at.formatted(time))  \(event.action.rawValue)  \(event.connection)  \(event.client)\(rows)")
            print("  \(event.sql.replacingOccurrences(of: "\n", with: " "))")
            if let detail = event.detail { print("  \(detail)") }
        }
    }
}
