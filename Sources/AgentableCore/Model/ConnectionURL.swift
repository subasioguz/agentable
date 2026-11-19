import Foundation

/// A profile parsed from a URL, plus the password the URL carried (if any).
public struct ParsedConnection: Sendable {
    public var profile: ConnectionProfile
    public var password: String?
}

public enum ConnectionURLError: Error, Equatable, CustomStringConvertible {
    case unsupportedScheme(String)
    case missingHost
    case missingPath
    case malformed

    public var description: String {
        switch self {
        case .unsupportedScheme(let scheme):
            "Unsupported URL scheme \"\(scheme)\". Use postgres://, sqlite:// or a file path."
        case .missingHost:
            "The URL has no host."
        case .missingPath:
            "The SQLite URL has no file path."
        case .malformed:
            "This does not look like a connection URL."
        }
    }
}

/// Parses `postgres://user:pass@host:5432/db?sslmode=require`, `sqlite:///path/to.db` and bare file paths.
public enum ConnectionURL {
    public static func parse(
        _ text: String,
        name: String,
        environment: DeploymentEnvironment
    ) throws -> ParsedConnection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConnectionURLError.malformed }

        if !trimmed.contains("://"), looksLikeFilePath(trimmed) {
            return ParsedConnection(
                profile: sqliteProfile(name: name, environment: environment, path: expandPath(trimmed)),
                password: nil
            )
        }

        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            throw ConnectionURLError.malformed
        }

        switch scheme {
        case "postgres", "postgresql":
            guard let host = components.host, !host.isEmpty else { throw ConnectionURLError.missingHost }
            var database = components.path
            if database.hasPrefix("/") { database.removeFirst() }
            var tls = TLSMode.prefer
            if let mode = components.queryItems?.first(where: { $0.name == "sslmode" })?.value {
                tls = tlsMode(fromSSLMode: mode)
            }
            let profile = ConnectionProfile(
                name: name,
                engine: .postgres,
                environment: environment,
                host: host,
                port: components.port,
                user: components.user,
                database: database.isEmpty ? nil : database,
                tls: tls
            )
            let password = components.password.flatMap { $0.isEmpty ? nil : $0 }
            return ParsedConnection(profile: profile, password: password)

        case "sqlite", "sqlite3", "file":
            let path = components.path
            guard !path.isEmpty else { throw ConnectionURLError.missingPath }
            return ParsedConnection(
                profile: sqliteProfile(name: name, environment: environment, path: expandPath(path)),
                password: nil
            )

        default:
            throw ConnectionURLError.unsupportedScheme(scheme)
        }
    }

    static func tlsMode(fromSSLMode mode: String) -> TLSMode {
        switch mode.lowercased() {
        case "disable": .disable
        case "require", "verify-ca": .require
        case "verify-full": .verifyFull
        default: .prefer
        }
    }

    private static func looksLikeFilePath(_ text: String) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("./") || text.hasPrefix("../") {
            return true
        }
        let lower = text.lowercased()
        return [".sqlite", ".sqlite3", ".db", ".db3"].contains { lower.hasSuffix($0) }
    }

    private static func expandPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
            .standardizedFileURL.path
    }

    private static func sqliteProfile(
        name: String,
        environment: DeploymentEnvironment,
        path: String
    ) -> ConnectionProfile {
        ConnectionProfile(name: name, engine: .sqlite, environment: environment, database: path, tls: .disable)
    }
}
