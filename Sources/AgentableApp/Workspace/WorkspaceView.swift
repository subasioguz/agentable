import AppKit
import SwiftUI
import AgentableCore

/// An open connection: header, icon rail, schema rail, the open table or review, and the session panel.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(workspace: workspace)
            HStack(spacing: 0) {
                IconRail {
                    RailButton(icon: .database, label: "Schema", selected: workspace.selected != .review) {
                        if workspace.selected == .review, let table = workspace.tabs.last(where: { $0 != .review }) {
                            workspace.selected = table
                        }
                    }
                    RailButton(
                        icon: .review,
                        label: workspace.changeCount == 0 ? "Review (nothing waiting)" : "Review, \(workspace.changeCount) waiting",
                        selected: workspace.selected == .review,
                        badge: workspace.changeCount > 0 ? (workspace.pending.isEmpty ? .tmYou : .tmAgent) : nil
                    ) { workspace.openReview() }
                    RailButton(
                        icon: .agents,
                        label: sessionShown ? "Hide agent session" : "Show agent session",
                        selected: sessionShown,
                        badge: workspace.presence.contains(where: \.isActive) ? .tmAgent : nil
                    ) {
                        if rowShown {
                            workspace.showRow = false
                            workspace.showSession = true
                        } else {
                            workspace.showSession.toggle()
                        }
                    }
                    Spacer()
                    RailButton(icon: .layers, label: "All connections") { app.showConnections() }
                    SettingsMenu()
                }
                content
            }
            StatusFooter(workspace: workspace)
        }
        .overlay(alignment: .top) {
            if workspace.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001).onTapGesture { workspace.showPalette = false }
                    GoToPalette(workspace: workspace).padding(.top, 72)
                }
            }
        }
    }

    /// The row panel takes the session panel's place while it is open on a table.
    private var rowShown: Bool { workspace.showRow && workspace.currentTable != nil }
    private var sessionShown: Bool { workspace.showSession && !rowShown }

    @ViewBuilder private var content: some View {
        switch workspace.status {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(workspace.profile.name)…").foregroundStyle(Color.tmMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text("Could not connect to \(workspace.profile.name)").font(.ui(17, .semibold))
                Text(message).font(.mono(12)).foregroundStyle(Color.tmText2).textSelection(.enabled)
                HStack {
                    Button("Try again") { Task { await workspace.connect() } }.buttonStyle(.primary)
                    Button("Edit connection") { app.showConnections() }.buttonStyle(.secondary)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            HStack(spacing: 0) {
                SchemaRail(workspace: workspace)
                    .frame(width: 236)
                Hairline(vertical: true)
                Group {
                    switch workspace.selected {
                    case .table(let table)?:
                        TableScreen(workspace: workspace, grid: workspace.grid(for: table))
                            .id(table)
                    case .review?:
                        ReviewView(workspace: workspace)
                    case nil:
                        Text("Pick a table on the left.").foregroundStyle(Color.tmMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                if let table = workspace.currentTable, workspace.openGrid(table)?.viewTab == .sql {
                    Hairline(vertical: true)
                    QueriesSidebar(workspace: workspace, document: workspace.grid(for: table).sql)
                        .frame(width: 288)
                } else if let table = workspace.currentTable, let grid = workspace.openGrid(table),
                          grid.viewTab == .structure, grid.structureSelection != nil {
                    Hairline(vertical: true)
                    StructurePanel(workspace: workspace, grid: grid)
                        .frame(width: 300)
                } else if rowShown, let table = workspace.currentTable {
                    Hairline(vertical: true)
                    RowPanel(workspace: workspace, grid: workspace.grid(for: table))
                        .frame(width: 356)
                } else if workspace.showSession {
                    Hairline(vertical: true)
                    SessionPanel(workspace: workspace)
                        .frame(width: 288)
                }
            }
        }
    }
}

struct WorkspaceHeader: View {
    @Environment(AppModel.self) private var app
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        HeaderBar {
            connectionMenu
            Hairline(vertical: true).frame(height: 18)
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs, id: \.self) { tab in
                        TabButton(tab: tab, workspace: workspace)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            presence
            GoToButton(workspace: workspace)
        }
    }

    private var connectionMenu: some View {
        Menu {
            ForEach(app.profiles) { profile in
                Button {
                    if profile.id != workspace.profile.id { app.open(profile) }
                } label: {
                    Text(verbatim: "\(profile.name)  ·  \(profile.environment.rawValue)")
                }
            }
            Divider()
            Button("All connections…") { app.showConnections() }
        } label: {
            HStack(spacing: 8) {
                Dot(color: workspace.profile.environment.dotColor, size: 8)
                Text(workspace.profile.name).font(.ui(13, .semibold)).foregroundStyle(Color.tmText)
                Text(verbatim: "\(workspace.profile.environment.rawValue) · \(workspace.profile.engine.displayName)")
                    .foregroundStyle(Color.tmMuted)
                IconView(.chevronDown, size: 13, weight: 2).foregroundStyle(Color.tmMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// "claude-code is editing with you" while its suggestion shows in the open query.
    private func presenceText(_ client: String) -> String {
        let sql = workspace.currentTable.flatMap { workspace.openGrid($0) }.flatMap { $0.viewTab == .sql ? $0.sql : nil }
        if sql?.askRun?.isRunning == true && sql?.askRun?.agent == client { return String(localized: "\(client) is working") }
        if sql?.suggestion?.client == client { return String(localized: "\(client) is editing with you") }
        return workspace.pending.contains { $0.client == client }
            ? String(localized: "\(client) is waiting for you") : String(localized: "\(client) is working")
    }

    @ViewBuilder private var presence: some View {
        let agents = workspace.presence
        HStack(spacing: 10) {
            HStack(spacing: -6) {
                Avatar(kind: .you, size: 28, ring: .tmSide).help("You")
                ForEach(agents.prefix(3)) { agent in
                    Avatar(kind: agent.isActive ? .agent : .idleAgent, size: 28, ring: .tmSide)
                        .help(agent.isActive ? String(localized: "\(agent.client), active") : String(localized: "\(agent.client), idle"))
                }
            }
            if let active = agents.first(where: \.isActive) {
                Text(presenceText(active.client))
                    .font(.ui(12)).foregroundStyle(Color.tmMuted)
            } else if !agents.isEmpty {
                (agents.count == 1 ? Text("\(agents[0].client) was here") : Text("\(agents.count) agents here"))
                    .font(.ui(12)).foregroundStyle(Color.tmMuted)
            }
        }
        .fixedSize()
    }
}

private struct TabButton: View {
    let tab: WorkspaceTab
    @Bindable var workspace: WorkspaceModel
    @State private var hovering = false

    var body: some View {
        let selected = workspace.selected == tab
        HStack(spacing: 7) {
            switch tab {
            case .table(let table):
                Text(table.name)
            case .review:
                IconView(.review, size: 13)
                Text("Review · \(workspace.changeCount)")
            }
            if hovering && workspace.tabs.count > 1 {
                Button {
                    workspace.closeTab(tab)
                } label: {
                    IconView(.close, size: 12, weight: 2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.tmMuted)
                .accessibilityLabel("Close tab")
            }
        }
        .font(.ui(13, selected ? .medium : .regular))
        .foregroundStyle(selected ? Color.tmText : Color.tmMuted)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(selected ? Color.tmWindow : (hovering ? Color.tmChip : .clear), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine) }
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.selected = tab }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct StatusFooter: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 16) {
            Text(locationLine)
            if let version = workspace.serverVersion { Text(version) }
            Spacer()
            if workspace.profile.environment == .production {
                Text("production writes go through review")
            } else {
                Text("your edits wait for review · agents: \(workspace.profile.effectiveAgentAccess.label)")
            }
        }
        .font(.mono(11.5))
        .foregroundStyle(Color.tmMuted)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.tmSide)
        .overlay(alignment: .top) { Hairline() }
    }

    private var locationLine: String {
        let profile = workspace.profile
        switch profile.engine {
        case .sqlite: return (profile.database as NSString?)?.abbreviatingWithTildeInPath ?? "sqlite"
        case .postgres:
            let server = "\(profile.host ?? "localhost"):\(profile.port ?? 5432) · tls \(profile.tls.rawValue)"
            return profile.ssh.map { "ssh \($0.host) · \(server)" } ?? server
        }
    }
}
