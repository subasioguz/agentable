import Foundation

/// Where Agentable keeps its files. `AGENTABLE_HOME` overrides the location (tests, portable setups).
public struct AgentablePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentablePaths {
        if let custom = environment["AGENTABLE_HOME"], !custom.isEmpty {
            return AgentablePaths(root: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let root = support.appending(path: "Agentable", directoryHint: .isDirectory)
        // The app was called Tablemate before; its folder moves over once.
        let legacy = support.appending(path: "Tablemate", directoryHint: .isDirectory)
        let files = FileManager.default
        if !files.fileExists(atPath: root.path), files.fileExists(atPath: legacy.path) {
            try? files.moveItem(at: legacy, to: root)
            // Connections to files that lived in the old folder (the demo database) follow it.
            let connections = root.appending(path: "connections.json")
            if let text = try? String(contentsOf: connections, encoding: .utf8) {
                let escaped = { (path: String) in path.replacingOccurrences(of: "/", with: "\\/") }
                let moved = text
                    .replacingOccurrences(of: legacy.path, with: root.path)
                    .replacingOccurrences(of: escaped(legacy.path), with: escaped(root.path))
                if moved != text { try? Data(moved.utf8).write(to: connections, options: .atomic) }
            }
        }
        return AgentablePaths(root: root)
    }

    public var connectionsFile: URL { root.appending(path: "connections.json") }
    public var stateDatabase: URL { root.appending(path: "state.sqlite") }

    public func ensureExists() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case notFound(String, known: [String])
    case duplicate(String)
    case invalidName(String)

    public var description: String {
        switch self {
        case .notFound(let name, let known):
            known.isEmpty
                ? "No connection named \(name). Add one with `agentable connections add`."
                : "No connection named \(name). Known: \(known.joined(separator: ", "))."
        case .duplicate(let name):
            "A connection named \(name) already exists."
        case .invalidName(let name):
            "\"\(name)\" is not a valid name. Use lower-case letters, digits, '-', '_' or '.', up to 64 characters."
        }
    }
}

/// Saved connections in a JSON file. Holds no secrets.
public struct ProfileStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(profiles.sorted { $0.name < $1.name })
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func profile(named name: String) throws -> ConnectionProfile {
        let profiles = try load()
        guard let profile = profiles.first(where: { $0.name == name }) else {
            throw StoreError.notFound(name, known: profiles.map(\.name))
        }
        return profile
    }

    public func add(_ profile: ConnectionProfile) throws {
        guard ConnectionProfile.isValidName(profile.name) else { throw StoreError.invalidName(profile.name) }
        var profiles = try load()
        guard !profiles.contains(where: { $0.name == profile.name }) else { throw StoreError.duplicate(profile.name) }
        profiles.append(profile)
        try save(profiles)
    }

    public func update(_ profile: ConnectionProfile) throws {
        var profiles = try load()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw StoreError.notFound(profile.name, known: profiles.map(\.name))
        }
        profiles[index] = profile
        try save(profiles)
    }

    @discardableResult
    public func remove(named name: String) throws -> ConnectionProfile {
        var profiles = try load()
        guard let index = profiles.firstIndex(where: { $0.name == name }) else {
            throw StoreError.notFound(name, known: profiles.map(\.name))
        }
        let removed = profiles.remove(at: index)
        try save(profiles)
        return removed
    }
}
