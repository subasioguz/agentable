import ArgumentParser
import Foundation
import AgentableCore

struct Connections: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage saved connections and what agents may do on them.",
        subcommands: [List.self, Add.self, Remove.self, SetAccess.self, Rules.self, AgentRoleCommand.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List connections.")
        @Flag var json = false

        func run() async throws {
            let profiles = try Context.make().profiles.load()
            if json {
                print(try AgentFormatter.json(profiles.map {
                    ["name": $0.name, "engine": $0.engine.rawValue, "environment": $0.environment.rawValue,
                     "agents": $0.effectiveAgentAccess.rawValue, "location": $0.location]
                }))
                return
            }
            guard !profiles.isEmpty else {
                print("No connections. Add one: agentable connections add <name> <url> --env local")
                return
            }
            for profile in profiles {
                let columns = [
                    profile.name.padding(toLength: 18, withPad: " ", startingAt: 0),
                    profile.engine.displayName.padding(toLength: 11, withPad: " ", startingAt: 0),
                    profile.environment.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0),
                    "agents: \(profile.effectiveAgentAccess.rawValue)".padding(toLength: 17, withPad: " ", startingAt: 0),
                    profile.location,
                ]
                print(columns.joined(separator: " "))
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a connection from a URL or a SQLite file path.")

        @Argument(help: "Name agents will use, e.g. acme-dev.") var name: String
        @Argument(help: "postgres://user@host:5432/db, sqlite:///path/to.db or a file path.") var url: String
        @Option(help: "local, dev, staging or production.") var env: DeploymentEnvironment = .local
        @Option(help: "Agent access: off, read, propose or write. Defaults by environment.") var access: AgentAccess?
        @Flag(help: "Read the password from standard input.") var passwordStdin = false

        func run() async throws {
            let context = try Context.make()
            var parsed = try ConnectionURL.parse(url, name: name, environment: env)
            parsed.profile.agentAccess = access
            if passwordStdin {
                parsed.password = readLine(strippingNewline: true)
            } else if parsed.password != nil {
                printStderr("Saved the password to Keychain. Passwords in URLs stay in shell history; prefer --password-stdin.")
            }
            try context.profiles.add(parsed.profile)
            try context.secrets.setPassword(parsed.password, for: parsed.profile.id)
            let profile = parsed.profile
            print("Added \(profile.name): \(profile.engine.displayName), \(profile.environment.rawValue), agents: \(profile.effectiveAgentAccess.rawValue)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a connection and its stored password.")
        @Argument var name: String

        func run() async throws {
            let context = try Context.make()
            let removed = try context.profiles.remove(named: name)
            try context.secrets.setPassword(nil, for: removed.id)
            print("Removed \(removed.name).")
        }
    }

    struct SetAccess: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-access",
            abstract: "Change what agents may do. Raising access asks for Touch ID or your password."
        )
        @Argument var name: String
        @Argument(help: "off, read, propose or write.") var level: AgentAccess

        func run() async throws {
            let context = try Context.make()
            var profile = try context.profiles.profile(named: name)
            let before = profile.effectiveAgentAccess
            profile.agentAccess = level
            let after = profile.effectiveAgentAccess
            if after > before {
                try await context.review.authenticator.authenticate(
                    reason: "let agents \(after.rawValue) on \(profile.name)"
                )
            }
            try context.profiles.update(profile)
            var message = "\(profile.name): agents \(before.rawValue) → \(after.rawValue)"
            if level > after { message += " (\(profile.environment.rawValue) allows at most \(after.rawValue))" }
            print(message)
        }
    }

    struct Rules: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hide tables or mask columns from agents. Removing a rule asks for Touch ID or your password."
        )
        @Argument var name: String
        @Option(help: "Table to hide.") var hide: [String] = []
        @Option(help: "table.column to mask.") var mask: [String] = []
        @Option(help: "Table to show again.") var unhide: [String] = []
        @Option(help: "table.column to stop masking.") var unmask: [String] = []

        func run() async throws {
            let context = try Context.make()
            var profile = try context.profiles.profile(named: name)
            if !unhide.isEmpty || !unmask.isEmpty {
                try await context.review.authenticator.authenticate(
                    reason: "show more data to agents on \(profile.name)"
                )
            }
            var rules = profile.rules
            rules.hiddenTables = unique(rules.hiddenTables + hide).filter { table in
                !unhide.contains { $0.caseInsensitiveCompare(table) == .orderedSame }
            }
            rules.maskedColumns = unique(rules.maskedColumns + mask).filter { column in
                !unmask.contains { $0.caseInsensitiveCompare(column) == .orderedSame }
            }
            profile.rules = rules
            try context.profiles.update(profile)
            print("\(profile.name): hidden [\(rules.hiddenTables.joined(separator: ", "))], masked [\(rules.maskedColumns.joined(separator: ", "))]")
        }

        private func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0.lowercased()).inserted }
        }
    }

    struct AgentRoleCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "agent-role",
            abstract: "Print SQL for a SELECT-only agent role, or make agents connect as it (asks for Touch ID or your password)."
        )
        @Argument var name: String
        @Option(help: "Role name.") var user = "agent_ro"
        @Flag(help: "Use this role for agent reads; reads its password from standard input.") var use = false

        func run() async throws {
            let context = try Context.make()
            var profile = try context.profiles.profile(named: name)
            guard profile.engine == .postgres else {
                print("SQLite has no roles: Agentable already opens the file read-only for agents.")
                return
            }
            guard use else {
                let session = try await DefaultSessionFactory().open(
                    profile, password: try context.secrets.password(for: profile.id), readOnly: true
                )
                let tables: [TableSummary]
                do {
                    tables = try await session.tables()
                    await session.close()
                } catch {
                    await session.close()
                    throw error
                }
                print(AgentRole.setupSQL(role: user, database: profile.database, tables: tables, rules: profile.rules))
                print("-- Then: agentable connections agent-role \(name) --user \(user) --use  (password on stdin)")
                return
            }
            guard let password = readLine(strippingNewline: true), !password.isEmpty else {
                throw ValidationError("Pipe the role's password on standard input.")
            }
            try await context.review.authenticator.authenticate(reason: "let agents on \(profile.name) connect as \(user)")
            let credential = profile.agentCredentialID ?? UUID()
            try context.secrets.setPassword(password, for: credential)
            profile.agentUser = user
            profile.agentCredentialID = credential
            try context.profiles.update(profile)
            print("\(profile.name): agents now read as \(user).")
        }
    }
}
