import Foundation
import LocalAuthentication

/// Confirms a person is at the Mac before anything that widens what agents can do: approving a
/// change, raising access, unhiding a table. An agent with a shell cannot answer a Touch ID prompt.
public protocol Authenticator: Sendable {
    func authenticate(reason: String) async throws
}

public enum AuthenticationError: Error, CustomStringConvertible {
    case unavailable(String)
    case declined

    public var description: String {
        switch self {
        case .unavailable(let message): "Cannot ask for confirmation on this Mac: \(message)"
        case .declined: "Not confirmed. Nothing was changed."
        }
    }
}

/// Touch ID, Apple Watch or the account password, through LocalAuthentication.
public struct DeviceOwnerAuthenticator: Authenticator {
    public init() {}

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw AuthenticationError.unavailable(error?.localizedDescription ?? "no authentication method")
        }
        do {
            let confirmed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard confirmed else { throw AuthenticationError.declined }
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel, .authenticationFailed, .userFallback:
                throw AuthenticationError.declined
            default:
                throw AuthenticationError.unavailable(laError.localizedDescription)
            }
        }
    }
}
