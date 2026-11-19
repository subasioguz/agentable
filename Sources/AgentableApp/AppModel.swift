import AppKit
import Foundation
import Observation
import AgentableCore

enum Appearance: String, CaseIterable {
    case system, light, dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The app's root state: saved connections, which screen is up and the open workspace.
@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable { case welcome, connections, workspace }
    /// The Connect agents window.
    var showAgents = Snapshot.isActive && Snapshot.scene == "agents"

    let paths: AgentablePaths
    let profileStore: ProfileStore
    let secrets: any SecretStore
    let sessions: any SessionFactory
    let authenticator: any Authenticator
    let state: StateStore
    let gateway: AgentGateway
    let review: ReviewService
    let feed: ActivityFeed

    private(set) var profiles: [ConnectionProfile] = []
    var screen: Screen = .connections
    private(set) var workspace: WorkspaceModel?
    var message: String?

    var appearance: Appearance {
        didSet {
            Defaults.set(appearance.rawValue, "appearance")
            NSApp.appearance = appearance.nsAppearance
        }
    }

    /// The order tables open in until their sort is changed.
    var defaultOrder: DefaultOrder {
        didSet {
            Defaults.set(defaultOrder.rawValue, "defaultOrder")
            workspace?.defaultOrderChanged()
        }
    }

    private(set) var lastUsed: [UUID: Date] = [:]

    init(paths: AgentablePaths = .standard()) throws {
        try paths.ensureExists()
        self.paths = paths
        profileStore = ProfileStore(file: paths.connectionsFile)
        secrets = KeychainSecretStore()
        sessions = DefaultSessionFactory()
        authenticator = DeviceOwnerAuthenticator()
        state = try StateStore(url: paths.stateDatabase)
        gateway = AgentGateway(profiles: profileStore, secrets: secrets, state: state, sessions: sessions)
        review = ReviewService(gateway: gateway, authenticator: authenticator)
        feed = ActivityFeed(state: state)
        appearance = Appearance(rawValue: Defaults.string("appearance") ?? "") ?? .system
        defaultOrder = DefaultOrder(rawValue: Defaults.string("defaultOrder") ?? "") ?? .oldestFirst

        let stored = Defaults.dictionary("lastUsed") as? [String: Double] ?? [:]
        lastUsed = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            UUID(uuidString: key).map { ($0, Date(timeIntervalSince1970: value)) }
        })
        reloadProfiles()
        let welcomed = Defaults.bool("welcomed")
        screen = profiles.isEmpty && !welcomed ? .welcome : .connections
        feed.start()
        // Connections can also be added with the CLI while the app is open.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadProfiles() }
        }
    }

    func reloadProfiles() {
        do {
            let loaded = try profileStore.load()
            if loaded != profiles { profiles = loaded }
        } catch {
            message = String(localized: "Could not read saved connections: \(String(describing: error))")
        }
    }

    // MARK: Workspace

    /// Opens a connection, on `table` or else the table last open there.
    func open(_ profile: ConnectionProfile, table: String? = nil) {
        workspace?.close()
        let workspace = WorkspaceModel(profile: profile, app: self)
        workspace.preferredTable = table ?? Defaults.string("lastTable.\(profile.id.uuidString)")
        self.workspace = workspace
        screen = .workspace
        lastUsed[profile.id] = .now
        Defaults.set(Dictionary(uniqueKeysWithValues: lastUsed.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }), "lastUsed")
        Task { await workspace.connect() }
    }

    func showConnections() {
        screen = .connections
    }

    func closeWorkspace() {
        workspace?.close()
        workspace = nil
        screen = .connections
    }

    func finishWelcome() {
        Defaults.set(true, "welcomed")
        screen = .connections
    }

    // MARK: Saving connections

    /// Saves a new or changed connection. Raising what agents may do asks the person to confirm,
    /// as in the CLI; lowering it never does.
    func save(_ profile: ConnectionProfile, password: String?, replacing original: ConnectionProfile?) async throws {
        let before = original?.effectiveAgentAccess ?? profile.environment.defaultAgentAccess
        if profile.effectiveAgentAccess > before {
            try await authenticator.authenticate(
                reason: String(localized: "let agents \(profile.effectiveAgentAccess.label) on \(profile.name)")
            )
        }
        if original != nil {
            try profileStore.update(profile)
        } else {
            try profileStore.add(profile)
        }
        if let password {
            try secrets.setPassword(password.isEmpty ? nil : password, for: profile.id)
        }
        reloadProfiles()
    }

    func remove(_ profile: ConnectionProfile) {
        do {
            if workspace?.profile.id == profile.id { closeWorkspace() }
            _ = try profileStore.remove(named: profile.name)
            try? secrets.setPassword(nil, for: profile.id)
            reloadProfiles()
        } catch {
            message = "\(error)"
        }
    }

    /// Connects once with the given settings and reports how long it took.
    func test(_ profile: ConnectionProfile, password: String?) async -> Result<Duration, Error> {
        let started = ContinuousClock.now
        do {
            let session = try await sessions.open(profile, password: password, readOnly: true)
            do {
                _ = try await session.run("SELECT 1", options: QueryOptions(readOnly: true, maxRows: 1, timeout: .seconds(10)))
                await session.close()
            } catch {
                await session.close()
                throw error
            }
            return .success(ContinuousClock.now - started)
        } catch {
            return .failure(error)
        }
    }
}
