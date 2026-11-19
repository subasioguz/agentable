import SwiftUI
import AgentableCore

/// The SQL tab's side panel: saved queries for this connection, and what ran on it lately, by
/// you and by agents. Clicking one puts it in the editor.
struct QueriesSidebar: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var document: SQLDocument
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldBox(height: 30) {
                IconView(.search, size: 13).foregroundStyle(Color.tmMuted)
                TextField("Search queries", text: $search).textFieldStyle(.plain)
            }
            .padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        SectionLabel(text: "Saved")
                        Spacer()
                        Button {
                            document.newQuery()
                        } label: {
                            HStack(spacing: 4) {
                                IconView(.plus, size: 12)
                                Text("New")
                            }
                        }
                        .buttonStyle(.text(height: 22, size: 12))
                        .help("Start an empty query")
                    }
                    .padding(.leading, 10)
                    .padding(.bottom, 4)
                    if saved.isEmpty && suggestedNew.isEmpty {
                        Text(search.isEmpty ? "No saved queries" : "No matches").font(.ui(12)).foregroundStyle(Color.tmMuted)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(suggestedNew) { suggestion in
                        row(dot: .tmAgent, title: suggestion.query, subtitle: String(localized: "\(suggestion.client) · suggested a new query"),
                            titleColor: .tmAgentText, selected: document.fileName == suggestion.query) {
                            workspace.openSavedQuery(suggestion.query)
                        }
                    }
                    ForEach(saved) { query in
                        let suggestion = workspace.suggestions.last { $0.query == query.name }
                        row(dot: suggestion == nil ? .tmYou : .tmAgent, title: query.name,
                            subtitle: suggestion.map { String(localized: "\($0.client) · suggested a change") }
                                ?? String(localized: "you · edited \(Self.ago(query.modified))"),
                            selected: document.file?.standardizedFileURL == query.url.standardizedFileURL) {
                            document.open(query.url)
                        }
                    }
                    SectionLabel(text: "Recent on \(workspace.profile.name)")
                        .padding(.leading, 10)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                    ForEach(recent) { item in
                        let event = item.event
                        let you = event.client == "you"
                        row(dot: you ? .tmYou : .tmAgent, title: Self.title(event.sql, dialect: workspace.dialect), subtitle: subtitle(event),
                            titleColor: event.action == .proposed ? .tmAgentText : .tmText, selected: false) {
                            document.load(event.sql)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.automatic)
        }
        .background(Color.tmPanel)
        .onAppear { workspace.reloadSavedQueries() }
    }

    private var saved: [SavedQuery] {
        let needle = search.lowercased()
        return workspace.savedQueries.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
    }

    /// Queries an agent suggested under names that aren't saved yet.
    private var suggestedNew: [SQLSuggestion] {
        let names = Set(workspace.savedQueries.map(\.name))
        let needle = search.lowercased()
        return workspace.suggestions.filter { !names.contains($0.query) && (needle.isEmpty || $0.query.lowercased().contains(needle)) }
    }

    private var recent: [LoggedEvent] {
        let needle = search.lowercased()
        let kept: Set<AuditEvent.Action> = [.read, .proposed, .write, .applied]
        return Array(workspace.events.reversed().filter {
            kept.contains($0.event.action) && (needle.isEmpty || $0.event.sql.lowercased().contains(needle))
        }.prefix(40))
    }

    private func row(dot: Color, title: String, subtitle: String, titleColor: Color = .tmText, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Dot(color: dot, size: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.mono(12.5, .medium)).foregroundStyle(titleColor).lineLimit(1)
                    Text(subtitle).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(Color.tmWindow)
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help(title)
    }

    private func subtitle(_ event: AuditEvent) -> String {
        let time = event.at.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(L10n.locale))
        // "you" is how the log names the person; agents go by their own names.
        let who = event.client == "you" ? String(localized: "you") : event.client
        switch event.action {
        case .proposed: return String(localized: "\(who) · became a proposal")
        case .write, .applied: return "\(who) · " + String(localized: "applied") + "\(rows(event)) · \(time)"
        default: return "\(who)\(rows(event)) · \(time)"
        }
    }

    private func rows(_ event: AuditEvent) -> String {
        event.rows.map { " · " + SessionLine.rows($0) } ?? ""
    }

    /// "SELECT … FROM payments", "UPDATE orders …".
    static func title(_ sql: String, dialect: SQLDialect) -> String {
        let verb = SQLAnalyzer.statements(in: sql, dialect: dialect).first?.verb ?? ""
        if let target = SQLAnalyzer.writeTarget(of: sql, dialect: dialect) {
            return "\(verb) \(target.name) …"
        }
        if let match = sql.range(of: #"(?i)\bfrom\s+("?[\w.]+"?)"#, options: .regularExpression) {
            let from = sql[match].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            return "\(verb.isEmpty ? "SELECT" : verb) … FROM \(from.replacingOccurrences(of: "\"", with: ""))"
        }
        return String(sql.split(whereSeparator: \.isNewline).first ?? "").prefix(40).description
    }

    static func ago(_ date: Date) -> String {
        if Date.now.timeIntervalSince(date) < 60 { return String(localized: "now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
