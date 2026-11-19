import Foundation
import Observation
import AgentableCore

/// An agent seen recently on a connection.
struct AgentPresence: Identifiable, Hashable {
    var client: String
    var lastSeen: Date
    /// Did something in the last few seconds.
    var isActive: Bool

    var id: String { client }
}

/// Follows the audit log and the review queue in `state.sqlite`. Agents run in other processes
/// (`agentable mcp`, the CLI); what they do reaches the app only through this file.
@MainActor
@Observable
final class ActivityFeed {
    private(set) var events: [LoggedEvent] = []
    private(set) var pending: [Proposal] = []
    /// Agents' suggestions for saved queries, waiting for the person.
    private(set) var suggestions: [SQLSuggestion] = []
    /// Bumps whenever events or proposals change.
    private(set) var revision = 0
    private(set) var now = Date.now

    @ObservationIgnored private let state: StateStore
    @ObservationIgnored private var lastID: Int64?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Events older than this no longer count as an agent being here.
    static let presenceWindow: TimeInterval = 15 * 60
    /// An agent that did something this recently is working right now.
    static let activeWindow: TimeInterval = 25

    init(state: StateStore) {
        self.state = state
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func poll() async {
        let fresh = (try? await state.loggedEvents(after: lastID, limit: 500)) ?? []
        // Presence fades on its own clock; a few seconds of slack keeps views from redrawing constantly.
        if !fresh.isEmpty || Date.now.timeIntervalSince(now) > 5 { now = .now }
        guard lastID == nil || !fresh.isEmpty else { return }
        if let last = fresh.last { lastID = last.id } else if lastID == nil { lastID = 0 }
        events.append(contentsOf: fresh)
        if events.count > 2_000 { events.removeFirst(events.count - 2_000) }
        pending = (try? await state.proposals(status: .pending)) ?? pending
        suggestions = (try? await state.suggestions(status: .pending)) ?? suggestions
        revision += 1
    }

    /// Re-reads the queue after the app itself changed it.
    func refresh() async {
        await poll()
        pending = (try? await state.proposals(status: .pending)) ?? pending
        suggestions = (try? await state.suggestions(status: .pending)) ?? suggestions
        revision += 1
    }

    func suggestions(on connection: String) -> [SQLSuggestion] {
        suggestions.filter { $0.connection == connection }
    }

    func events(on connection: String) -> [LoggedEvent] {
        events.filter { $0.event.connection == connection }
    }

    func pending(on connection: String) -> [Proposal] {
        pending.filter { $0.connection == connection }
    }

    /// Agents with recent activity on the connection, most recent first.
    func presence(on connection: String) -> [AgentPresence] {
        var latest: [String: Date] = [:]
        for item in events where item.event.connection == connection && item.event.client != "you" {
            latest[item.event.client] = max(latest[item.event.client] ?? .distantPast, item.event.at)
        }
        return latest
            .filter { now.timeIntervalSince($0.value) < Self.presenceWindow }
            .map { AgentPresence(client: $0.key, lastSeen: $0.value, isActive: now.timeIntervalSince($0.value) < Self.activeWindow) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// The newest agent event on the connection.
    func latestAgentEvent(on connection: String) -> AuditEvent? {
        events.last { $0.event.connection == connection && $0.event.client != "you" }?.event
    }
}
