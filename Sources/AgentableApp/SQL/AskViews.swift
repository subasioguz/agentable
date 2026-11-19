import SwiftUI
import AgentableCore

/// "Ask ⌘I" in the SQL toolbar; opens the Ask box under it.
struct AskButton: View {
    @Bindable var document: SQLDocument
    @Binding var popover: FilterPopover?
    @State private var frame = CGRect.zero

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                IconView(.agent, size: 14)
                Text("Ask")
                Text("⌘I").font(.mono(11)).foregroundStyle(Color.tmMuted)
            }
        }
        .buttonStyle(.secondary(height: 30))
        .background(popover?.kind == .ask ? Color.tmChip : .clear, in: RoundedRectangle(cornerRadius: 8))
        .help("Ask your agent to change or explain this query")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FilterPopover.space)) } action: { new in
            frame = new
            if SnapshotHooks.openAsk, new.width > 0 {
                SnapshotHooks.openAsk = false
                // After the tab switch, which closes open panels, has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { popover = FilterPopover(kind: .ask, anchor: frame) }
            }
        }
        .onChange(of: document.askRequested) {
            guard document.askRequested else { return }
            document.askRequested = false
            popover = FilterPopover(kind: .ask, anchor: frame)
        }
    }

    private func toggle() {
        popover = popover?.kind == .ask ? nil : FilterPopover(kind: .ask, anchor: frame)
    }
}

/// The Ask box: what the person wants, sent to their own Claude Code with only Agentable's tools.
struct AskPanel: View {
    let document: SQLDocument
    let connection: String
    let onDone: () -> Void
    @State private var request = ""
    @State private var name = ""
    @State private var problem: String?
    @State private var installed = true
    @FocusState private var focus: Field?

    enum Field { case request, name }

    /// One-click requests, in the person's language: they are the person's words to the agent.
    static var quick: [String] {
        [String(localized: "Make it faster"), String(localized: "Explain the plan"), String(localized: "Check for mistakes")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Avatar(kind: .agent, size: 22)
                Text("Ask claude-code").font(.ui(13, .semibold)).foregroundStyle(Color.tmText)
                Text("about \(Text(document.fileName ?? String(localized: "this query")).font(.mono(12)))")
                .font(.ui(13))
                .foregroundStyle(Color.tmMuted)
                .lineLimit(1)
            }
            if document.file == nil {
                FieldBox(height: 30, focused: focus == .name) {
                    TextField(String(localized: "ask.saveAs", defaultValue: "Save as"), text: $name).textFieldStyle(.plain).font(.mono(12.5)).focused($focus, equals: .name)
                    Text(".sql").font(.mono(12.5)).foregroundStyle(Color.tmMuted)
                }
            }
            TextField("What should it do with this query?", text: $request, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .lineLimit(3...6)
                .focused($focus, equals: .request)
                .focusEffectDisabled()
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(minHeight: 74, alignment: .topLeading)
                .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == .request ? Color.tmYou : Color.tmLine))
                .onSubmit { send(request) }
            HStack(spacing: 6) {
                ForEach(Self.quick, id: \.self) { text in
                    Button(text) { send(text) }
                        .buttonStyle(.secondary(height: 26))
                        .font(.ui(12))
                }
            }
            if let problem {
                Text(problem).font(.ui(12)).foregroundStyle(Color.tmBad).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    IconView(.lock, size: 14).foregroundStyle(Color.tmMuted).padding(.top, 1)
                    Text(installed
                         ? "Runs your Claude Code with Agentable's tools only. It reads and suggests; nothing runs until you accept."
                         : "Claude Code isn't installed on this Mac.")
                        .font(.ui(12)).foregroundStyle(Color.tmMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    send(request)
                } label: {
                    HStack(spacing: 8) {
                        Text("Send")
                        Text("⌘↩").font(.mono(11)).opacity(0.7)
                    }
                }
                .buttonStyle(.primary(height: 30))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!installed || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Hairline(color: .tmLine2) }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear {
            installed = AgentSetup.detect().first { $0.kind == .claudeCode }?.executable != nil
            if Snapshot.isActive && Snapshot.scene == "sql-ask" { request = "Only count successful payments, and show each customer's name." }
            focus = document.file == nil ? .name : .request
        }
    }

    private func send(_ text: String) {
        guard installed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try document.ask(text, saveAs: name)
            onDone()
        } catch {
            problem = "\(error)"
            focus = .name
        }
    }
}

/// While the agent works, and its answer when it has words rather than a change, as on board 14.
struct AskCard: View {
    @Bindable var document: SQLDocument
    let run: AskRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.tmAgentTint, lineWidth: 3))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(run.agent).font(.ui(12.5, .semibold)).foregroundStyle(Color.tmAgentText)
            content
            Button(run.isRunning ? "Stop" : "Close") {
                run.isRunning ? document.stopAsking() : document.closeAsk()
            }
            .buttonStyle(.secondary(height: 26))
            .font(.ui(12))
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.tmWindow)
                .shadow(color: Color.tmShadow.opacity(0.45), radius: 12, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.tmLine))
    }

    private var dotColor: Color {
        switch run.state {
        case .running: .tmAgent
        case .failed: .tmBad
        default: .tmMuted
        }
    }

    @ViewBuilder private var content: some View {
        switch run.state {
        case .running:
            Text(run.request).font(.ui(12.5)).foregroundStyle(Color.tmText2).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(run.startedAt))
                Text((run.steps + [(run.current ?? String(localized: "thinking")) + "…", String(localized: "\(seconds) s")]).joined(separator: " · "))
                    .font(.mono(11.5)).foregroundStyle(Color.tmMuted).lineLimit(1)
                    // The current step and the seconds matter most; older steps give way first.
                    .truncationMode(.head)
            }
        case .answered(let answer):
            // Agents write `code` in backticks; inline Markdown shows it as code.
            Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer))
                .font(.ui(12.5)).foregroundStyle(Color.tmText2).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Text(message).font(.ui(12.5)).foregroundStyle(Color.tmBad).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .stopped:
            Text("Stopped.").font(.ui(12.5)).foregroundStyle(Color.tmMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .suggested:
            EmptyView()
        }
    }
}
