import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// How to reach a database through an SSH server. Anything left empty comes from `~/.ssh/config`:
/// the tunnel runs the system's OpenSSH, so keys, the SSH agent, `ProxyJump` and `known_hosts` all
/// work as they do in Terminal. Passwords are not supported.
public struct SSHSettings: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int?
    public var user: String?
    public var identityFile: String?

    public init(host: String, port: Int? = nil, user: String? = nil, identityFile: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
    }

    /// "bastion-eu-1 · ~/.ssh/id_ed25519"
    public var summary: String {
        var server = user.map { "\($0)@\(host)" } ?? host
        if let port, port != 22 { server += ":\(port)" }
        return [server, identityFile].compactMap { $0 }.joined(separator: " · ")
    }

    /// Arguments for `/usr/bin/ssh` that forward `127.0.0.1:localPort` to the database. Values that
    /// could be read as options are refused, so a name can never smuggle in `-oProxyCommand`.
    public func arguments(localPort: Int, targetHost: String, targetPort: Int) throws -> [String] {
        try Self.check(host, "SSH host")
        if let user { try Self.check(user, "SSH user") }
        try Self.check(targetHost, "database host")
        let target = targetHost.contains(":") ? "[\(targetHost)]" : targetHost
        var arguments = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-L", "127.0.0.1:\(localPort):\(target):\(targetPort)",
        ]
        if let port { arguments += ["-p", String(port)] }
        if let identityFile, !identityFile.isEmpty {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        if let user { arguments += ["-l", user] }
        return arguments + ["--", host]
    }

    private static func check(_ value: String, _ what: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        guard !value.isEmpty, !value.hasPrefix("-"), value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DatabaseError.unsupported("The \(what) “\(value)” has characters an SSH tunnel can't use.")
        }
    }

    /// A short explanation of why OpenSSH gave up.
    static func explain(_ stderr: String, host: String) -> String {
        if stderr.contains("Host key verification failed") || stderr.contains("No ED25519 host key") || stderr.contains("No RSA host key") {
            return "\(host) is not in ~/.ssh/known_hosts. Connect once in Terminal with `ssh \(host)`, check the fingerprint, then try again."
        }
        if stderr.contains("Permission denied") {
            return "\(host) refused the SSH key. Agentable uses your SSH agent, ~/.ssh/config or the key file you chose; passwords are not supported."
        }
        if stderr.contains("Could not resolve hostname") { return "Could not find the SSH host \(host)." }
        let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return last.isEmpty ? "The SSH tunnel to \(host) closed." : "SSH: \(last)"
    }
}

/// Certificate files for TLS to PostgreSQL: a CA to trust, and a client certificate and key.
public struct TLSFiles: Codable, Sendable, Hashable {
    public var rootCertificate: String?
    public var clientCertificate: String?
    public var clientKey: String?

    public init(rootCertificate: String? = nil, clientCertificate: String? = nil, clientKey: String? = nil) {
        self.rootCertificate = rootCertificate
        self.clientCertificate = clientCertificate
        self.clientKey = clientKey
    }

    public var isEmpty: Bool {
        [rootCertificate, clientCertificate, clientKey].allSatisfy { ($0 ?? "").isEmpty }
    }
}

/// Open SSH tunnels, shared by every session of this process. A tunnel stays open while sessions
/// use it and for a short while after, so quick reconnects reuse it; all close when the process ends.
public final class SSHTunnels: @unchecked Sendable {
    public static let shared = SSHTunnels()

    private final class Entry {
        let process: Process
        let port: Int
        var users = 0
        var idle: DispatchWorkItem?

        init(process: Process, port: Int) {
            self.process = process
            self.port = port
        }
    }

    private let lock = NSLock()
    private var open: [String: Entry] = [:]
    private var registeredExit = false
    static let idleSeconds = 30.0

    /// A local port that leads to `targetHost:targetPort` through the SSH server, and a function to
    /// call once the session using it is closed.
    public func acquire(_ settings: SSHSettings, targetHost: String, targetPort: Int) async throws -> (port: Int, release: @Sendable () -> Void) {
        let key = "\(settings.summary)|\(settings.identityFile ?? "")|\(targetHost):\(targetPort)"
        if let port = reuse(key) {
            return (port, { [self] in release(key) })
        }
        let port = try Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try settings.arguments(localPort: port, targetHost: targetHost, targetPort: targetPort)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DatabaseError.openFailed("Could not start ssh: \(error.localizedDescription)")
        }
        registerExit()

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw DatabaseError.openFailed(SSHSettings.explain(text, host: settings.host))
            }
            if Self.accepts(port) {
                let entry = Entry(process: process, port: port)
                entry.users = 1
                lock.withLock { open[key] = entry }
                return (port, { [self] in release(key) })
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw DatabaseError.openFailed("The SSH tunnel to \(settings.host) did not open within 20 seconds.")
    }

    private func reuse(_ key: String) -> Int? {
        lock.withLock {
            guard let entry = open[key] else { return nil }
            guard entry.process.isRunning else {
                open[key] = nil
                return nil
            }
            entry.idle?.cancel()
            entry.idle = nil
            entry.users += 1
            return entry.port
        }
    }

    private func release(_ key: String) {
        lock.withLock {
            guard let entry = open[key] else { return }
            entry.users -= 1
            guard entry.users <= 0 else { return }
            let work = DispatchWorkItem { [weak self] in self?.closeIfIdle(key) }
            entry.idle = work
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.idleSeconds, execute: work)
        }
    }

    private func closeIfIdle(_ key: String) {
        lock.withLock {
            guard let entry = open[key], entry.users <= 0 else { return }
            entry.process.terminate()
            open[key] = nil
        }
    }

    /// Ends every tunnel; runs by itself when the process exits.
    public func closeAll() {
        lock.withLock {
            for entry in open.values { entry.process.terminate() }
            open.removeAll()
        }
    }

    private func registerExit() {
        lock.withLock {
            guard !registeredExit else { return }
            registeredExit = true
            atexit { SSHTunnels.shared.closeAll() }
        }
    }

    // MARK: Sockets

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError.openFailed("Could not find a free local port for the SSH tunnel.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        guard bound == 0 else { throw DatabaseError.openFailed("Could not find a free local port for the SSH tunnel.") }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func accepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}
