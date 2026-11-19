import Foundation

/// Finds coding agents on this Mac and adds Agentable's MCP server to them.
///
/// Claude Code and Codex are set up with their own `mcp add` commands, so their config files
/// are written by their own code. Cursor has no such command: its `mcp.json` is backed up next
/// to itself before Agentable adds one entry.
struct AgentSetup: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case claudeCode, codex, cursor
    }

    enum State: Hashable {
        case notFound
        case available
        case connected
    }

    let kind: Kind
    var state: State
    /// The agent's CLI, when it has one.
    var executable: URL?

    var id: Kind { kind }

    var name: String {
        switch kind {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var configPath: String {
        switch kind {
        case .claudeCode: "~/.claude.json"
        case .codex: "~/.codex/config.toml"
        case .cursor: "~/.cursor/mcp.json"
        }
    }

    var subtitle: String {
        "\(kind == .cursor ? String(localized: "App") : "CLI") · \(configPath)"
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The `agentable` CLI agents should run: inside the app bundle, or next to this executable.
    static var cliPath: String? {
        let candidates = [
            Bundle.main.bundleURL.appending(path: "Contents/Helpers/agentable"),
            Bundle.main.bundleURL.appending(path: "Contents/MacOS/agentable"),
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "agentable"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.resolvingSymlinksInPath().path
    }

    static func detect() -> [AgentSetup] {
        Kind.allCases.map { kind in
            switch kind {
            case .claudeCode:
                let binary = findExecutable("claude", extra: [home.appending(path: ".claude/local/claude").path])
                let config = read(".claude.json")
                let connected = config.map { mentionsServer($0, key: "\"agentable\"") } ?? false
                return AgentSetup(kind: kind, state: connected ? .connected : (binary == nil ? .notFound : .available), executable: binary)
            case .codex:
                let binary = findExecutable("codex", extra: [])
                let connected = read(".codex/config.toml")?.contains("[mcp_servers.agentable]") ?? false
                return AgentSetup(kind: kind, state: connected ? .connected : (binary == nil ? .notFound : .available), executable: binary)
            case .cursor:
                let installed = FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
                    || FileManager.default.fileExists(atPath: home.appending(path: ".cursor").path)
                let connected = read(".cursor/mcp.json").map { mentionsServer($0, key: "\"agentable\"") } ?? false
                return AgentSetup(kind: kind, state: connected ? .connected : (installed ? .available : .notFound), executable: nil)
            }
        }
    }

    /// Adds the MCP server. Returns what to tell the person.
    func connect() throws -> String {
        guard let cli = Self.cliPath else { throw SetupError.noCLI }
        switch kind {
        case .claudeCode, .codex:
            guard let executable else { throw SetupError.notFound(name) }
            let arguments = kind == .claudeCode
                ? ["mcp", "add", "--scope", "user", "agentable", "--", cli, "mcp"]
                : ["mcp", "add", "agentable", "--", cli, "mcp"]
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw SetupError.failed(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return String(localized: "\(name) can use Agentable now.")
        case .cursor:
            let url = Self.home.appending(path: ".cursor/mcp.json")
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url) {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SetupError.unreadable(url.path) }
                root = parsed
                try data.write(to: url.appendingPathExtension("agentable-backup"))
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["agentable"] = ["command": cli, "args": ["mcp"]]
            root["mcpServers"] = servers
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            return String(localized: "Added to Cursor. The old file is saved as mcp.json.agentable-backup.")
        }
    }

    /// The JSON most MCP clients accept.
    static var genericConfig: String {
        let cli = cliPath ?? "/path/to/agentable"
        return """
            {
              "mcpServers": {
                "agentable": { "command": "\(cli)", "args": ["mcp"] }
              }
            }
            """
    }

    enum SetupError: Error, CustomStringConvertible {
        case noCLI, notFound(String), failed(String), unreadable(String)

        var description: String {
            switch self {
            case .noCLI: String(localized: "The agentable command-line tool was not found next to the app.")
            case .notFound(let name): String(localized: "\(name) was not found on this Mac.")
            case .failed(let output): output.isEmpty ? String(localized: "The agent's setup command failed.") : output
            case .unreadable(let path): String(localized: "\(path) is not valid JSON, so it was left alone.")
            }
        }
    }

    private static func read(_ relative: String) -> String? {
        try? String(contentsOf: home.appending(path: relative), encoding: .utf8)
    }

    /// Whether the config's server list names Agentable. A plain text check: it only decides
    /// which button to show.
    private static func mentionsServer(_ text: String, key: String) -> Bool {
        guard let range = text.range(of: "\"mcpServers\"") else { return false }
        return text[range.upperBound...].contains(key)
    }

    private static func findExecutable(_ name: String, extra: [String]) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appending(path: ".local/bin").path, home.appending(path: ".npm-global/bin").path]
        for directory in paths {
            let candidate = URL(fileURLWithPath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return extra.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
