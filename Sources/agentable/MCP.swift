import ArgumentParser
import Foundation
import AgentableCore

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the Model Context Protocol over stdio for coding agents."
    )

    func run() async throws {
        let server = MCPServer(gateway: try Context.make().gateway)
        // stdout carries protocol messages only; anything else goes to stderr.
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how to connect Claude Code, Codex and Cursor to Agentable."
    )

    func run() throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().standardizedFileURL.path
        print("""
            Claude Code (all projects):
              claude mcp add --scope user agentable -- \(path) mcp

            Codex, in ~/.codex/config.toml:
              [mcp_servers.agentable]
              command = "\(path)"
              args = ["mcp"]

            Cursor, in ~/.cursor/mcp.json:
              { "mcpServers": { "agentable": { "command": "\(path)", "args": ["mcp"] } } }

            Agents see only connections whose access is not off: agentable connections
            """)
    }
}
