import Foundation

/// Database engines Agentable can talk to.
public enum DatabaseEngine: String, Codable, Sendable, CaseIterable {
    case postgres
    case sqlite

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .sqlite: "SQLite"
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .postgres: 5432
        case .sqlite: nil
        }
    }

    var dialect: SQLDialect {
        switch self {
        case .postgres: .postgres
        case .sqlite: .sqlite
        }
    }
}

/// Where a database lives. Drives safe mode and what agents may do by default.
public enum DeploymentEnvironment: String, Codable, Sendable, CaseIterable {
    case local, dev, staging, production

    /// What agents may do on a new connection in this environment until the user changes it.
    public var defaultAgentAccess: AgentAccess {
        switch self {
        case .production: .read
        case .staging: .propose
        case .dev, .local: .write
        }
    }

    /// Agents never write to production directly: the most they can do there is propose.
    public var maximumAgentAccess: AgentAccess {
        self == .production ? .propose : .write
    }
}

/// What agents may do on a connection.
public enum AgentAccess: String, Codable, Sendable, CaseIterable, Comparable {
    /// Agents cannot see the connection.
    case off
    /// Schema and read-only queries within the limits.
    case read
    /// Read, plus changes that wait in the review queue for a person.
    case propose
    /// Read and write directly. Never available on production.
    case write

    private var rank: Int {
        switch self {
        case .off: 0
        case .read: 1
        case .propose: 2
        case .write: 3
        }
    }

    public static func < (lhs: AgentAccess, rhs: AgentAccess) -> Bool { lhs.rank < rhs.rank }
}

public enum TLSMode: String, Codable, Sendable, CaseIterable {
    case disable, prefer, require
    case verifyFull = "verify-full"
}

/// Tables agents cannot see and columns whose values they only see masked.
public struct VisibilityRules: Codable, Sendable, Hashable {
    /// `table` or `schema.table`, matched case-insensitively on the table name.
    public var hiddenTables: [String]
    /// `table.column` or `schema.table.column`, matched case-insensitively.
    public var maskedColumns: [String]

    public init(hiddenTables: [String] = [], maskedColumns: [String] = []) {
        self.hiddenTables = hiddenTables
        self.maskedColumns = maskedColumns
    }

    public var isEmpty: Bool { hiddenTables.isEmpty && maskedColumns.isEmpty }
}

/// Bounds on every agent request.
public struct AgentLimits: Codable, Sendable, Hashable {
    public var maxRows: Int
    public var timeoutSeconds: Double
    /// Longer cell values are cut in agent output.
    public var maxCellCharacters: Int

    public init(maxRows: Int = 500, timeoutSeconds: Double = 10, maxCellCharacters: Int = 200) {
        self.maxRows = maxRows
        self.timeoutSeconds = timeoutSeconds
        self.maxCellCharacters = maxCellCharacters
    }

    public static let standard = AgentLimits()
}

/// A saved connection. Passwords never live here; they are in the `SecretStore`.
public struct ConnectionProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Agents address connections by this name.
    public var name: String
    public var engine: DatabaseEngine
    public var environment: DeploymentEnvironment
    public var host: String?
    public var port: Int?
    public var user: String?
    /// Database name; for SQLite, the file path.
    public var database: String?
    public var tls: TLSMode
    /// Certificate files for TLS (PostgreSQL).
    public var tlsFiles: TLSFiles? = nil
    /// Reach the database through an SSH server. Agents never see these settings.
    public var ssh: SSHSettings? = nil
    /// `nil` means the environment's default.
    public var agentAccess: AgentAccess?
    public var rules: VisibilityRules
    public var limits: AgentLimits
    /// Database user agents connect as for reads (e.g. a SELECT-only `agent_ro`); `nil` uses `user`.
    public var agentUser: String?
    /// Keychain key for the agent user's password.
    public var agentCredentialID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        engine: DatabaseEngine,
        environment: DeploymentEnvironment,
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        database: String? = nil,
        tls: TLSMode = .prefer,
        agentAccess: AgentAccess? = nil,
        rules: VisibilityRules = VisibilityRules(),
        limits: AgentLimits = .standard,
        agentUser: String? = nil,
        agentCredentialID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.environment = environment
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.tls = tls
        self.agentAccess = agentAccess
        self.rules = rules
        self.limits = limits
        self.agentUser = agentUser
        self.agentCredentialID = agentCredentialID
    }

    /// The level that actually applies, after the environment's cap.
    public var effectiveAgentAccess: AgentAccess {
        min(agentAccess ?? environment.defaultAgentAccess, environment.maximumAgentAccess)
    }

    /// Where the database is, without credentials. Safe for listings and logs.
    public var location: String {
        switch engine {
        case .sqlite:
            return database ?? "(no file)"
        case .postgres:
            let userPart = user.map { "\($0)@" } ?? ""
            let portPart = port.map { ":\($0)" } ?? ""
            return "\(userPart)\(host ?? "localhost")\(portPart)/\(database ?? "")"
        }
    }

    /// Lower-case letters, digits, `-`, `_` and `.`; starts with a letter or digit; at most 64 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64 else { return false }
        let lowerOrDigit = CharacterSet.lowercaseLetters.union(.decimalDigits)
        guard lowerOrDigit.contains(first), first.isASCII else { return false }
        let allowed = lowerOrDigit.union(CharacterSet(charactersIn: "-_."))
        return name.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, engine, environment, host, port, user, database, tls, tlsFiles, ssh, agentAccess, rules, limits, agentUser, agentCredentialID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        engine = try c.decode(DatabaseEngine.self, forKey: .engine)
        environment = try c.decode(DeploymentEnvironment.self, forKey: .environment)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        database = try c.decodeIfPresent(String.self, forKey: .database)
        tls = try c.decodeIfPresent(TLSMode.self, forKey: .tls) ?? .prefer
        tlsFiles = try c.decodeIfPresent(TLSFiles.self, forKey: .tlsFiles)
        ssh = try c.decodeIfPresent(SSHSettings.self, forKey: .ssh)
        agentAccess = try c.decodeIfPresent(AgentAccess.self, forKey: .agentAccess)
        rules = try c.decodeIfPresent(VisibilityRules.self, forKey: .rules) ?? VisibilityRules()
        limits = try c.decodeIfPresent(AgentLimits.self, forKey: .limits) ?? .standard
        agentUser = try c.decodeIfPresent(String.self, forKey: .agentUser)
        agentCredentialID = try c.decodeIfPresent(UUID.self, forKey: .agentCredentialID)
    }
}
