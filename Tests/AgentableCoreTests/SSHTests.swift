import Foundation
import Testing
@testable import AgentableCore

@Suite struct SSHTests {
    @Test func tunnelArgumentsForwardOneLocalPort() throws {
        let settings = SSHSettings(host: "bastion-eu-1", port: 2222, user: "deploy", identityFile: "~/.ssh/id_ed25519")
        let arguments = try settings.arguments(localPort: 55001, targetHost: "db-eu-2.internal", targetPort: 5432)
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("127.0.0.1:55001:db-eu-2.internal:5432"))
        #expect(Array(arguments.suffix(2)) == ["--", "bastion-eu-1"])
        #expect(arguments.contains(NSHomeDirectory() + "/.ssh/id_ed25519"))
        #expect(settings.summary == "deploy@bastion-eu-1:2222 · ~/.ssh/id_ed25519")
        #expect(try SSHSettings(host: "bastion").arguments(localPort: 1, targetHost: "::1", targetPort: 5432).contains("127.0.0.1:1:[::1]:5432"))
    }

    @Test func refusesValuesThatLookLikeOptions() {
        #expect(throws: DatabaseError.self) { try SSHSettings(host: "-oProxyCommand=open -a Calculator").arguments(localPort: 1, targetHost: "db", targetPort: 1) }
        #expect(throws: DatabaseError.self) { try SSHSettings(host: "bastion", user: "-v").arguments(localPort: 1, targetHost: "db", targetPort: 1) }
        #expect(throws: DatabaseError.self) { try SSHSettings(host: "bastion").arguments(localPort: 1, targetHost: "db; rm -rf ~", targetPort: 1) }
    }

    @Test func explainsCommonFailures() {
        #expect(SSHSettings.explain("Host key verification failed.\n", host: "bastion").contains("known_hosts"))
        #expect(SSHSettings.explain("deploy@bastion: Permission denied (publickey).\n", host: "bastion").contains("passwords are not supported"))
    }

    @Test func profilesKeepTunnelAndCertificates() throws {
        var profile = ConnectionProfile(name: "acme", engine: .postgres, environment: .production)
        profile.ssh = SSHSettings(host: "bastion", user: "deploy")
        profile.tlsFiles = TLSFiles(rootCertificate: "~/certs/ca.pem")
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.ssh == profile.ssh && decoded.tlsFiles == profile.tlsFiles)
        #expect(!decoded.location.contains("bastion"))
    }
}

@Suite struct SSHProcessTests {
    @Test func reportsWhyTheTunnelDidNotOpen() async throws {
        // Port 1 on this Mac refuses at once: the real ssh starts, fails, and its reason comes back.
        let settings = SSHSettings(host: "127.0.0.1", port: 1)
        do {
            _ = try await SSHTunnels.shared.acquire(settings, targetHost: "db.internal", targetPort: 5432)
            Issue.record("expected the tunnel to fail")
        } catch let error as DatabaseError {
            #expect("\(error)".contains("Connection refused"))
        }
    }
}
