import AppKit
import SwiftUI
import AgentableCore

/// First launch: connect a database, then let agents in.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var step = 1
    @State private var draft: ConnectionDraft?

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar {
                Text("Welcome").font(.ui(13, .semibold))
                Spacer()
            }
            ScrollView {
                VStack(spacing: 26) {
                    titleRow
                    HStack(alignment: .top, spacing: 20) {
                        databaseCard.frame(width: 360)
                        AgentsCard()
                            .opacity(step >= 2 ? 1 : 0.5)
                            .disabled(step < 2)
                    }
                    footer
                }
                .frame(maxWidth: 1080)
                .padding(.horizontal, 32)
                .padding(.top, 36)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.tmWindow)
        .sheet(item: $draft) { draft in
            ConnectionForm(draft: draft) {
                self.draft = nil
                if !app.profiles.isEmpty && step == 1 { step = 2 }
            }
            .frame(width: 440, height: 640)
            .background(Color.tmPanel)
        }
        .onAppear {
            step = app.profiles.isEmpty ? 1 : 2
            if Snapshot.isActive { step = Snapshot.scene == "welcome-agents" ? 2 : 1 }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect a database, then let your agents in.").font(.ui(30, .semibold)).tracking(-0.75)
                Text("Two minutes. Agents get a name for each connection, never the password.")
                    .font(.ui(14)).foregroundStyle(Color.tmText2)
            }
            Spacer()
            HStack(spacing: 14) {
                stepBadge(1, "Database")
                Rectangle().fill(Color.tmLine).frame(width: 28, height: 1.5)
                stepBadge(2, "Agents")
                Rectangle().fill(Color.tmLine).frame(width: 28, height: 1.5)
                stepBadge(3, "Done")
            }
        }
    }

    private func stepBadge(_ number: Int, _ label: LocalizedStringKey) -> some View {
        let done = number < step
        let current = number == step
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.tmOK : (current ? Color.tmText : .clear))
                Circle().strokeBorder(done ? Color.tmOK : (current ? Color.tmText : Color.tmLine), lineWidth: 1.5)
                if done {
                    IconView(.check, size: 13, weight: 2).foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(number)").font(.ui(12, .semibold)).foregroundStyle(current ? Color.tmWindow : Color.tmMuted)
                }
            }
            .frame(width: 24, height: 24)
            Text(label)
                .font(.ui(13, current ? .semibold : .regular))
                .foregroundStyle(done ? Color.tmOK : (current ? Color.tmText : Color.tmMuted))
        }
    }

    // MARK: Step 1

    private var databaseCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let profile = app.profiles.first {
                HStack(spacing: 12) {
                    IconView(.check, size: 16, weight: 2)
                        .foregroundStyle(Color.tmOK)
                        .frame(width: 36, height: 36)
                        .background(Color.tmOK.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.profiles.count == 1 ? "\(profile.name) is saved" : "\(app.profiles.count) connections saved").font(.ui(13, .semibold))
                        Text(verbatim: "\(profile.engine.displayName) · \(profile.environment.rawValue)").font(.mono(12)).foregroundStyle(Color.tmMuted)
                    }
                }
                .padding(16)
                Text("Passwords are in Keychain. Agents will address it as \(profile.name).")
                    .font(.ui(12.5)).foregroundStyle(Color.tmText2)
                    .padding(.horizontal, 16).padding(.bottom, 12)
                SectionLabel(text: "Add another")
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Hairline(color: .tmLine2) }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your first database").font(.ui(17, .semibold)).tracking(-0.17)
                    Text("PostgreSQL or a SQLite file. You can add more later.").foregroundStyle(Color.tmText2)
                }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
            }
            option(.link, "Paste a connection URL") { draft = ConnectionDraft() }
            option(.file, "Open a SQLite file") { openSQLite() }
            option(.server, "Enter host and port") {
                var new = ConnectionDraft()
                new.host = "localhost"
                new.port = "5432"
                draft = new
            }
        }
        .background(Color.tmWindow)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.tmLine))
    }

    private func option(_ icon: Icon, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconView(icon, size: 16).foregroundStyle(Color.tmText2).frame(width: 18)
                Text(title).foregroundStyle(Color.tmText)
                Spacer()
                IconView(.chevronRight, size: 13, weight: 2).foregroundStyle(Color.tmMuted)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Hairline(color: .tmLine2) }
    }

    private func openSQLite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a SQLite database file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var new = ConnectionDraft()
        _ = new.apply(url: url.path)
        new.url = url.path
        draft = new
    }

    // MARK: Step 2

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip for now") { app.finishWelcome() }
                .buttonStyle(QuietButtonStyle(size: nil))
            Spacer()
            if step > 1 {
                Button("Back") { step -= 1 }.buttonStyle(.secondary)
            }
            Button(step >= 2 ? "Done" : "Continue") {
                if step >= 2 {
                    finish()
                } else if app.profiles.isEmpty {
                    draft = ConnectionDraft()
                } else {
                    step = 2
                }
            }
            .buttonStyle(.primary)
        }
    }

    private func finish() {
        app.finishWelcome()
        if app.profiles.count == 1, let profile = app.profiles.first { app.open(profile) }
    }
}

/// The MCP tools, as chips.
struct ToolList: View {
    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Text("Agents get \(MCPServer.toolNames.count) tools:").font(.ui(12.5)).foregroundStyle(Color.tmText2).padding(.trailing, 4)
            ForEach(MCPServer.toolNames, id: \.self) { tool in
                Text(tool).font(.mono(12)).foregroundStyle(Color.tmText)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Color.tmChip, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
