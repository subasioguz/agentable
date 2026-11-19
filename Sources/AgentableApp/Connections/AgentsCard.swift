import AppKit
import SwiftUI
import AgentableCore

/// The agents on this Mac with a Connect button each, another agent's config to copy, and what
/// agents may do by default. Shown on first launch and in Connect agents later.
struct AgentsCard: View {
    @State private var agents: [AgentSetup] = AgentSetup.detect()
    @State private var message: (text: String, ok: Bool)?
    @State private var working: AgentSetup.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agents found on this Mac").font(.ui(17, .semibold)).tracking(-0.17)
                Text("Connecting adds Agentable as an MCP server in the agent's config. You can remove it anytime.")
                    .foregroundStyle(Color.tmText2)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            ForEach(agents) { agent in
                agentRow(agent)
            }
            HStack(spacing: 14) {
                glyph(.braces, tint: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Another agent").font(.ui(13, .semibold))
                    Text("Run \(Text(verbatim: "agentable mcp").font(.mono(12)).foregroundStyle(Color.tmText)) or copy the MCP config")
                        .foregroundStyle(Color.tmMuted)
                        .font(.ui(12.5))
                }
                Spacer()
                Button("Copy config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentSetup.genericConfig, forType: .string)
                    message = (String(localized: "Copied. Paste it into the agent's MCP settings."), true)
                }
                .buttonStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(alignment: .top) { Hairline(color: .tmLine2) }

            if let message {
                Text(message.text).font(.ui(12.5)).foregroundStyle(message.ok ? Color.tmOK : Color.tmBad)
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("What agents can do by default").font(.ui(13, .semibold))
                    Text("per environment; change it on each connection").font(.ui(12.5)).foregroundStyle(Color.tmMuted)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    defaultsRow(.production, label: "Production", note: "never more than propose")
                    defaultsRow(.staging, label: "Staging", note: nil)
                    defaultsRow(.local, label: "Local, dev", note: nil)
                }
                ToolList().padding(.top, 6)
            }
            .padding(16)
            .background(Color.tmPanel)
            .overlay(alignment: .top) { Hairline() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .card(radius: 14, shadow: 0.35)
    }

    private func glyph(_ icon: Icon, tint: Bool) -> some View {
        IconView(icon, size: 16)
            .foregroundStyle(tint ? Color.tmAgentText : Color.tmText2)
            .frame(width: 36, height: 36)
            .background(tint ? Color.tmAgentTint : Color.tmChip, in: RoundedRectangle(cornerRadius: 10))
    }

    private func agentRow(_ agent: AgentSetup) -> some View {
        HStack(spacing: 14) {
            glyph(agent.kind == .cursor ? .pointer : .agents, tint: agent.state == .connected)
                .opacity(agent.state == .notFound ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.ui(13, .semibold))
                Text(agent.state == .notFound ? String(localized: "Not found on this Mac") : agent.subtitle).font(.ui(12.5)).foregroundStyle(Color.tmMuted)
            }
            Spacer()
            switch agent.state {
            case .connected:
                HStack(spacing: 6) {
                    IconView(.check, size: 14, weight: 2)
                    Text("Connected")
                }
                .font(.ui(13, .semibold))
                .foregroundStyle(Color.tmOK)
            case .available:
                let primary = agents.first { $0.state == .available }?.kind == agent.kind
                Group {
                    if primary {
                        Button(working == agent.kind ? "Connecting…" : "Connect") { connect(agent) }.buttonStyle(.primary)
                    } else {
                        Button(working == agent.kind ? "Connecting…" : "Connect") { connect(agent) }.buttonStyle(.secondary)
                    }
                }
                .disabled(working != nil || AgentSetup.cliPath == nil)
            case .notFound:
                EmptyView()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(alignment: .top) { Hairline(color: .tmLine2) }
    }

    private func connect(_ agent: AgentSetup) {
        working = agent.kind
        Task.detached {
            let result = Result { try agent.connect() }
            await MainActor.run {
                working = nil
                switch result {
                case .success(let text): message = (text, true)
                case .failure(let error): message = (String(describing: error), false)
                }
                agents = AgentSetup.detect()
            }
        }
    }

    /// `label` is the environment's name, which stays English like the environments themselves.
    private func defaultsRow(_ environment: DeploymentEnvironment, label: String, note: LocalizedStringKey?) -> some View {
        GridRow {
            HStack(spacing: 8) {
                Dot(color: environment.dotColor)
                Text(label)
            }
            .frame(width: 110, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(AgentAccess.allCases, id: \.self) { level in
                    let on = level == environment.defaultAgentAccess
                    Text(level.label.capitalized(with: L10n.locale))
                        .font(.ui(12.5, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.tmText : (level > environment.maximumAgentAccess ? Color.tmMuted.opacity(0.5) : Color.tmText2))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 6).fill(Color.tmWindow).shadow(color: .black.opacity(0.1), radius: 1, y: 1) }
                        }
                }
            }
            .padding(3)
            .background(Color.tmChip, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) default: \(environment.defaultAgentAccess.label)")
            if let note {
                Text(note).font(.ui(12)).foregroundStyle(Color.tmMuted)
            }
        }
    }
}

/// Connect agents, any time after first launch: the same card in a window of its own.
struct AgentsSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect agents").font(.ui(20, .semibold)).tracking(-0.4)
                    Text("Agents get a name for each connection, never the password.")
                        .font(.ui(13)).foregroundStyle(Color.tmText2)
                }
                Spacer()
                Button("Done") { app.showAgents = false }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            AgentsCard()
        }
        .padding(24)
        .frame(width: 740)
        .background(Color.tmWindow)
    }
}
