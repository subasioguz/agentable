import SwiftUI
import AgentableCore

/// "Go to anything": jump to a table on this connection or to another connection by typing.
struct GoToPalette: View {
    @Environment(AppModel.self) private var app
    @Bindable var workspace: WorkspaceModel
    @State private var text = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private enum Target: Hashable {
        case table(TableRef)
        case connection(ConnectionProfile)
    }

    private var matches: [Target] {
        let needle = text.lowercased()
        let tables = workspace.tables
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .map { Target.table(TableRef($0)) }
        let connections = app.profiles
            .filter { $0.id != workspace.profile.id && (needle.isEmpty || $0.name.lowercased().contains(needle)) }
            .map { Target.connection($0) }
        return Array((tables + connections).prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldBox(height: 38) {
                IconView(.search, size: 15).foregroundStyle(Color.tmMuted)
                TextField("Go to a table or connection", text: $text)
                    .textFieldStyle(.plain)
                    .font(.ui(14))
                    .focused($focused)
                    .onSubmit { open(index) }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(0, matches.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onExitCommand { workspace.showPalette = false }
                    .onChange(of: text) { index = 0 }
            }
            VStack(spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element) { position, target in
                    Button { open(position) } label: { row(target, selected: position == index) }
                        .buttonStyle(.plain)
                }
                if matches.isEmpty {
                    Text("Nothing called “\(text)”").foregroundStyle(Color.tmMuted).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .frame(width: 520)
        .card()
        .onAppear { focused = true }
    }

    @ViewBuilder private func row(_ target: Target, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch target {
            case .table(let table):
                IconView(.views, size: 14).foregroundStyle(Color.tmMuted)
                Text(table.name).font(.mono(12.5)).foregroundStyle(Color.tmText)
                Spacer()
                if let count = workspace.estimates[table] {
                    Text(count.compact).font(.mono(11.5)).foregroundStyle(Color.tmMuted)
                }
            case .connection(let profile):
                Dot(color: profile.environment.dotColor, size: 7).frame(width: 14)
                Text(profile.name).foregroundStyle(Color.tmText)
                Text(profile.environment.rawValue).font(.ui(12)).foregroundStyle(Color.tmMuted)
                Spacer()
                Text("connection").font(.ui(12)).foregroundStyle(Color.tmMuted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(selected ? Color.tmChip : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func open(_ position: Int) {
        guard matches.indices.contains(position) else { return }
        workspace.showPalette = false
        switch matches[position] {
        case .table(let table): workspace.open(table)
        case .connection(let profile): app.open(profile)
        }
    }
}

/// The header's "Go to anything ⌘K" field, as drawn.
struct GoToButton: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        Button { workspace.showPalette = true } label: {
            HStack(spacing: 8) {
                IconView(.search, size: 14)
                Text("Go to anything")
                Spacer()
                KeyCap(text: "⌘K")
            }
            .foregroundStyle(Color.tmMuted)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(width: 240, height: 30)
            .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
    }
}
