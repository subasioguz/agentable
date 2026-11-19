import SwiftUI
import AgentableCore

/// What agents (and you) did on this connection today, newest at the bottom.
struct SessionPanel: View {
    @Environment(AppModel.self) private var app
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Session").font(.ui(14, .semibold))
                Text("today on \(workspace.profile.name)").font(.ui(12)).foregroundStyle(Color.tmMuted)
                Spacer()
                Button {
                    workspace.showSession = false
                } label: {
                    IconView(.close, size: 13)
                }
                .buttonStyle(QuietButtonStyle(size: 24))
                .help("Hide the session (⌥⌘0, or the agents button in the rail)")
                .accessibilityLabel("Hide session")
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.top, 12)
            .padding(.bottom, 10)

            let groups = SessionGroup.make(from: todaysEvents, tables: Set(workspace.tables.map { $0.name.lowercased() }))
            if groups.isEmpty {
                Text("No agent activity today.").foregroundStyle(Color.tmMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Hairline(color: .tmLine2) }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                SessionGroupView(group: group, workspace: workspace, active: isActive(group, groups))
                                    .id(group.id)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(groups.last?.id, anchor: .bottom) }
                    .onChange(of: groups.last?.id) { _, id in withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }

            Spacer(minLength: 0)
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.tmPanel)
    }

    private var todaysEvents: [LoggedEvent] {
        let start = Calendar.current.startOfDay(for: .now)
        return workspace.events.filter { $0.event.at >= start }
    }

    private func isActive(_ group: SessionGroup, _ groups: [SessionGroup]) -> Bool {
        guard group.client != "you", group.id == groups.last(where: { $0.client == group.client })?.id else { return false }
        return app.feed.now.timeIntervalSince(group.end) < ActivityFeed.activeWindow
    }

    private var footer: some View {
        let profile = workspace.profile
        let masked = profile.rules.maskedColumns.count
        let hidden = profile.rules.hiddenTables.count
        var parts = [Self.accessSentence(profile.effectiveAgentAccess)]
        if masked > 0 { parts.append(masked == 1 ? String(localized: "1 column is masked.") : String(localized: "\(masked) columns are masked.")) }
        if hidden > 0 { parts.append(hidden == 1 ? String(localized: "1 table is hidden.") : String(localized: "\(hidden) tables are hidden.")) }
        return HStack(alignment: .top, spacing: 8) {
            IconView(.access, size: 13).foregroundStyle(Color.tmMuted).padding(.top, 1)
            Text(parts.joined(separator: " ")).fixedSize(horizontal: false, vertical: true)
        }
        .font(.ui(12))
        .foregroundStyle(Color.tmMuted)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }

    static func accessSentence(_ access: AgentAccess) -> String {
        switch access {
        case .off: String(localized: "Agents cannot see this connection here.")
        case .read: String(localized: "Agents only read here.")
        case .propose: String(localized: "Agents read and propose here.")
        case .write: String(localized: "Agents read and write here.")
        }
    }
}

/// Consecutive events from one client, shown as one entry.
struct SessionGroup: Identifiable {
    var id: Int64
    var client: String
    var start: Date
    var end: Date
    var lines: [SessionLine]

    static func make(from events: [LoggedEvent], tables: Set<String>) -> [SessionGroup] {
        var groups: [SessionGroup] = []
        for item in events {
            let line = SessionLine(item, tables: tables)
            if var last = groups.last, last.client == item.event.client, item.event.at.timeIntervalSince(last.end) < 90 {
                last.lines.append(line)
                last.end = item.event.at
                groups[groups.count - 1] = last
            } else {
                groups.append(SessionGroup(id: item.id, client: item.event.client, start: item.event.at, end: item.event.at, lines: [line]))
            }
        }
        return groups
    }
}

struct SessionLine: Identifiable {
    enum Style { case mono, prose, warning, failure }

    var id: Int64
    var text: String
    /// Quieter tail, such as "· 214 rows".
    var suffix: String?
    var detail: String?
    var style: Style
    var proposalID: String?
    /// A saved query an agent suggested a change to.
    var suggestedQuery: String?

    init(_ item: LoggedEvent, tables: Set<String>) {
        id = item.id
        let event = item.event
        let names = Self.tables(in: event.sql, known: tables)
        let target = names.isEmpty ? nil : names.joined(separator: ", ")
        let count = event.rows.map { "· " + Self.rows($0) }
        let rows = count.map { " " + $0 } ?? ""
        switch event.action {
        case .read:
            text = target.map { String(localized: "read \($0)") } ?? String(localized: "session.read", defaultValue: "read")
            suffix = count
            style = .mono
        case .write where event.client == "you":
            // The person's own writes carry the line the review service logged.
            text = event.detail ?? ((target.map { String(localized: "changed \($0)") } ?? String(localized: "changed")) + rows)
            style = .mono
        case .write:
            text = target.map { String(localized: "wrote \($0)") } ?? String(localized: "wrote")
            suffix = count
            style = .mono
        case .proposed:
            text = Self.proposed(verb: event.sql.split(separator: " ").first.map { $0.lowercased() } ?? "", target: target)
            suffix = count
            style = .prose
            proposalID = event.detail
        case .denied:
            text = String(localized: "was refused")
            detail = event.detail
            style = .warning
        case .applied:
            if event.client == "you" {
                text = (target.map { String(localized: "applied a proposed change to \($0)") } ?? String(localized: "applied a proposed change")) + rows
            } else {
                text = (target.map { String(localized: "applied \($0)") } ?? String(localized: "applied")) + rows
            }
            style = .prose
        case .rejected:
            text = String(localized: "turned down a proposed change")
            detail = event.detail
            style = .prose
        case .failed:
            text = String(localized: "session.failed", defaultValue: "failed")
            detail = event.detail
            style = .failure
        case .opened:
            // "saved queries" is what the gateway logs for the list; anything else names one query.
            if event.detail == "saved queries" {
                text = String(localized: "looked at your saved queries")
            } else {
                text = event.detail.map { String(localized: "read \($0)") } ?? String(localized: "read a saved query")
            }
            style = event.detail == "saved queries" ? .prose : .mono
        case .suggested:
            text = event.detail.map { String(localized: "suggested a change to \($0)") } ?? String(localized: "suggested a change to a saved query")
            style = .prose
            suggestedQuery = event.detail
        case .accepted:
            text = event.detail.map { String(localized: "took the suggestion for \($0)") } ?? String(localized: "took the suggestion for a saved query")
            style = .prose
        case .dismissed:
            text = event.detail.map { String(localized: "dismissed the suggestion for \($0)") } ?? String(localized: "dismissed the suggestion for a saved query")
            style = .prose
        case .asked:
            text = event.detail.map { String(localized: "asked \($0)") } ?? String(localized: "asked an agent")
            style = .prose
        }
    }

    /// "1 row", "214 rows"
    static func rows(_ count: Int) -> String {
        count == 1 ? String(localized: "1 row") : String(localized: "\(count.grouped) rows")
    }

    /// "proposed an update to orders"
    private static func proposed(verb: String, target: String?) -> String {
        switch (verb, target) {
        case ("update", let target?): String(localized: "proposed an update to \(target)")
        case ("update", nil): String(localized: "proposed an update")
        case ("delete", let target?): String(localized: "proposed a delete to \(target)")
        case ("delete", nil): String(localized: "proposed a delete")
        case ("insert", let target?): String(localized: "proposed an insert to \(target)")
        case ("insert", nil): String(localized: "proposed an insert")
        case (_, let target?): String(localized: "proposed a change to \(target)")
        case (_, nil): String(localized: "proposed a change")
        }
    }

    /// Known table names the SQL mentions, in order of appearance.
    static func tables(in sql: String, known: Set<String>) -> [String] {
        let lowered = sql.lowercased()
        return known
            .compactMap { name in SQLText.lastIndex(of: name, in: lowered).map { (name, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
            .prefix(3)
            .map { $0 }
    }
}

private struct SessionGroupView: View {
    let group: SessionGroup
    @Bindable var workspace: WorkspaceModel
    let active: Bool

    var body: some View {
        let you = group.client == "you"
        HStack(alignment: .top, spacing: 10) {
            Avatar(kind: you ? .you : (active ? .agent : .agent), size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(you ? String(localized: "You") : group.client).font(.ui(13, .semibold))
                    Text(active ? String(localized: "now") : L10n.time(group.start))
                        .font(.mono(11)).foregroundStyle(Color.tmMuted)
                }
                ForEach(group.lines.suffix(6)) { line in
                    SessionLineView(line: line, workspace: workspace)
                }
                if group.lines.count > 6 {
                    Text("and \(group.lines.count - 6) earlier").font(.ui(12)).foregroundStyle(Color.tmMuted)
                }
                if active {
                    HStack(spacing: 8) {
                        Circle().fill(Color.tmAgent).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color.tmAgentTint, lineWidth: 3))
                        Text(workspace.pending.contains { $0.client == group.client } || workspace.suggestions.contains { $0.client == group.client }
                             ? String(localized: "waiting for your review") : String(localized: "working…"))
                            .foregroundStyle(Color.tmText2)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Hairline(color: .tmLine2) }
    }
}

private struct SessionLineView: View {
    let line: SessionLine
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch line.style {
            case .mono:
                (Text(line.text).foregroundStyle(Color.tmText) + Text(line.suffix.map { " " + $0 } ?? "").foregroundStyle(Color.tmMuted))
                    .font(.mono(12))
            case .prose:
                (Text(line.text).foregroundStyle(Color.tmText) + Text(line.suffix.map { " " + $0 } ?? "").foregroundStyle(Color.tmMuted))
            case .warning:
                Text(line.text).foregroundStyle(Color.tmWarn)
            case .failure:
                Text(line.text).foregroundStyle(Color.tmBad)
            }
            if let detail = line.detail {
                Text(detail).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(3)
            }
            if let id = line.proposalID, let proposal = workspace.pending.first(where: { $0.id == id }) {
                if let reason = proposal.reason {
                    Text(reason).font(.ui(12.5)).foregroundStyle(Color.tmText2).fixedSize(horizontal: false, vertical: true)
                }
                Button("Review") { workspace.openReview(selecting: id) }
                    .buttonStyle(.secondary(height: 24))
                    .font(.ui(12))
                    .padding(.top, 2)
            }
            if let query = line.suggestedQuery, let suggestion = workspace.suggestions.last(where: { $0.query == query }) {
                if let note = suggestion.note {
                    Text(note).font(.ui(12.5)).foregroundStyle(Color.tmText2).fixedSize(horizontal: false, vertical: true)
                }
                Button("Open") { workspace.openSavedQuery(query) }
                    .buttonStyle(.secondary(height: 24))
                    .font(.ui(12))
                    .padding(.top, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
