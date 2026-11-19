import Foundation
import Security

/// Connection passwords. Agents never receive them: Agentable opens connections on their behalf.
public protocol SecretStore: Sendable {
    func password(for profileID: UUID) throws -> String?
    /// `nil` removes the stored password.
    func setPassword(_ password: String?, for profileID: UUID) throws
}

public enum SecretStoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Stores passwords as generic passwords in the login keychain.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "dev.agentable.connection") {
        self.service = service
    }

    /// Where passwords were kept when the app was called Tablemate.
    static let legacyService = "dev.tablemate.connection"

    public func password(for profileID: UUID) throws -> String? {
        if let password = try read(profileID, service: service) { return password }
        // Moved over from the old name the first time it is needed.
        guard service != Self.legacyService, let legacy = try read(profileID, service: Self.legacyService) else { return nil }
        try setPassword(legacy, for: profileID)
        try? KeychainSecretStore(service: Self.legacyService).setPassword(nil, for: profileID)
        return legacy
    }

    private func read(_ profileID: UUID, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for profileID: UUID) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        let deleted = SecItemDelete(match as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw SecretStoreError.keychain(deleted)
        }
        guard let password else { return }
        var attributes = match
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Agentable connection"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }
}

/// For tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var passwords: [UUID: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func password(for profileID: UUID) throws -> String? {
        lock.withLock { passwords[profileID] }
    }

    public func setPassword(_ password: String?, for profileID: UUID) throws {
        lock.withLock { passwords[profileID] = password }
    }
}
