import AppKit
import SwiftUI
import AgentableCore

/// Saved connections grouped by environment, with the new-connection panel on the right.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var draft: ConnectionDraft?
    @State private var removing: ConnectionProfile?

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar {
                Text("Connections").font(.ui(13, .semibold))
                Spacer()
                Button {
                    app.showAgents = true
                } label: {
                    HStack(spacing: 6) {
                        IconView(.agents, size: 14)
                        Text("Connect agents")
                    }
                }
                .buttonStyle(.secondary(height: 30))
                .help("Add Agentable to Claude Code, Codex or Cursor")
                if let workspace = app.workspace {
                    Button {
                        app.screen = .workspace
                    } label: {
                        HStack(spacing: 6) {
                            Dot(color: workspace.profile.environment.dotColor, size: 7)
                            Text("Back to \(workspace.profile.name)")
                        }
                    }
                    .buttonStyle(.secondary(height: 30))
                }
            }
            HStack(spacing: 0) {
                IconRail {
                    RailButton(icon: .database, label: "Connections", selected: true) {}
                    Spacer()
                    SettingsMenu()
                }
                list
                if let draft {
                    Hairline(vertical: true)
                    ConnectionForm(draft: draft) { self.draft = nil }
                        .id(draft.id)
                        .frame(width: 420)
                        .background(Color.tmPanel)
                }
            }
        }
        .onAppear {
            if Snapshot.openNewConnection {
                var sample = ConnectionDraft()
                sample.url = "postgres://app@db-eu-2.internal:5432/acme"
                _ = sample.apply(url: sample.url)
                sample.name = "acme-replica"
                sample.environment = .production
                draft = sample
            }
        }
        .alert(
            "Remove \(removing?.name ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { profile in
            Button("Remove", role: .destructive) { app.remove(profile) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The saved settings and the password in Keychain are deleted. Agents can no longer use this name.")
        }
    }

    private var filtered: [ConnectionProfile] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return app.profiles }
        return app.profiles.filter { $0.name.lowercased().contains(needle) || $0.location.lowercased().contains(needle) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Connections").font(.ui(24, .semibold)).tracking(-0.48)
                Text("\(app.profiles.count) saved · passwords live in Keychain").foregroundStyle(Color.tmMuted)
                Spacer()
                Button {
                    draft = ConnectionDraft()
                } label: {
                    Label("New connection", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.primary)
                .keyboardShortcut("n", modifiers: .command)
            }

            FieldBox {
                IconView(.search, size: 14).foregroundStyle(Color.tmMuted)
                TextField("Search by name or host", text: $search)
                    .textFieldStyle(.plain)
            }

            if app.profiles.isEmpty {
                EmptyConnections { draft = ConnectionDraft() }
            } else {
                ScrollView {
                    ConnectionTable(profiles: filtered, onOpen: { app.open($0) }, onEdit: { draft = ConnectionDraft($0) }, onRemove: { removing = $0 })
                }
                .scrollIndicators(.automatic)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tmWindow)
    }
}

private struct EmptyConnections: View {
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No connections yet").font(.ui(15, .semibold))
            Text("Paste a postgres:// URL or pick a SQLite file.")
                .foregroundStyle(Color.tmText2)
            Button("New connection", action: onNew).buttonStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.tmLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct ConnectionTable: View {
    @Environment(AppModel.self) private var app
    let profiles: [ConnectionProfile]
    let onOpen: (ConnectionProfile) -> Void
    let onEdit: (ConnectionProfile) -> Void
    let onRemove: (ConnectionProfile) -> Void

    private let order: [DeploymentEnvironment] = [.production, .staging, .dev, .local]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                header("Name").frame(maxWidth: .infinity, alignment: .leading)
                header("Host").frame(width: 300, alignment: .leading)
                header("Agents").frame(width: 150, alignment: .leading)
                header("Last used").frame(width: 110, alignment: .leading)
                Color.clear.frame(width: 36)
            }
            .frame(height: 32)
            .overlay(alignment: .bottom) { Hairline() }

            ForEach(order, id: \.self) { environment in
                let group = profiles.filter { $0.environment == environment }.sorted { $0.name < $1.name }
                if !group.isEmpty {
                    Text(environment.title.uppercased())
                        .font(.ui(11, .semibold))
                        .tracking(0.66)
                        .foregroundStyle(environment.headingColor)
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(group) { profile in
                        ConnectionRow(profile: profile, onOpen: onOpen, onEdit: onEdit, onRemove: onRemove)
                    }
                }
            }
        }
    }

    private func header(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.ui(12, .semibold)).foregroundStyle(Color.tmMuted).padding(.horizontal, 12)
    }
}

private struct ConnectionRow: View {
    @Environment(AppModel.self) private var app
    let profile: ConnectionProfile
    let onOpen: (ConnectionProfile) -> Void
    let onEdit: (ConnectionProfile) -> Void
    let onRemove: (ConnectionProfile) -> Void
    @State private var hovering = false

    var body: some View {
        let live = app.feed.presence(on: profile.name).filter(\.isActive).count
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Dot(color: profile.environment.dotColor, size: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(profile.name).font(.ui(13, .semibold)).foregroundStyle(Color.tmText)
                    Text(profile.engine.displayName).font(.ui(12)).foregroundStyle(Color.tmMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(profile.engine == .sqlite ? (profile.location as NSString).abbreviatingWithTildeInPath : profile.location)
                .font(.mono(12))
                .foregroundStyle(Color.tmText2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .frame(width: 300, alignment: .leading)

            HStack(spacing: 6) {
                if live > 0 { Dot(color: .tmAgent, size: 6) }
                Text(verbatim: profile.effectiveAgentAccess.label + (live > 0 ? " · " + String(localized: "\(live) live") : ""))
                    .foregroundStyle(profile.effectiveAgentAccess == .off ? Color.tmMuted : Color.tmText2)
            }
            .padding(.horizontal, 12)
            .frame(width: 150, alignment: .leading)

            Text(verbatim: app.lastUsed[profile.id].map(Self.relative) ?? String(localized: "never"))
                .foregroundStyle(Color.tmText2)
                .padding(.horizontal, 12)
                .frame(width: 110, alignment: .leading)

            Button {
                onEdit(profile)
            } label: {
                IconView(.edit, size: 14)
            }
            .buttonStyle(.quiet)
            .opacity(hovering ? 1 : 0)
            .help("Edit")
            .frame(width: 36)
        }
        .frame(height: 52)
        .background(hovering ? Color.tmPanel : Color.clear)
        .overlay(alignment: .bottom) { Hairline(color: .tmLine2) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 1) { onOpen(profile) }
        .contextMenu {
            Button("Open") { onOpen(profile) }
            Button("Edit…") { onEdit(profile) }
            Divider()
            Button("Copy name for agents") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(profile.name, forType: .string)
            }
            Divider()
            Button("Remove…", role: .destructive) { onRemove(profile) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "now") }
        if seconds < 3_600 { return String(localized: "\(Int(seconds / 60)) min ago") }
        if seconds < 86_400 { return String(localized: "\(Int(seconds / 3_600)) h ago") }
        if seconds < 172_800 { return String(localized: "yesterday") }
        return String(localized: "\(Int(seconds / 86_400)) days ago")
    }
}
