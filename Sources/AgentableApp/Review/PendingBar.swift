import SwiftUI
import AgentableCore

/// "4 changes waiting": your edits and agents' proposals, one step from review.
struct PendingBar: View {
    @Bindable var workspace: WorkspaceModel
    /// On the Structure tab: counts schema changes and, on production, offers "Review DDL".
    var structure = false
    @State private var confirmDiscard = false

    var body: some View {
        let mine = workspace.staged.count
        let byAgent = Dictionary(grouping: workspace.pending, by: \.client)
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 14) {
            if mine > 0 {
                Button {
                    workspace.showChangeList.toggle()
                } label: {
                    HStack(spacing: 8) {
                        IconView(workspace.showChangeList ? .chevronDown : .chevronRight, size: 14).foregroundStyle(Color.tmMuted)
                        Text(waitingText).font(.ui(13, .semibold)).foregroundStyle(Color.tmText)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, -6)
                .help(workspace.showChangeList ? "Hide your changes" : "Show your changes")
            } else {
                Text(waitingText).font(.ui(13, .semibold))
            }
            if mine > 0 {
                HStack(spacing: 6) {
                    Dot(color: .tmYou)
                    Text("\(mine) yours")
                }
                .foregroundStyle(Color.tmText2)
            }
            ForEach(byAgent.keys.sorted(), id: \.self) { client in
                HStack(spacing: 6) {
                    Dot(color: .tmAgent)
                    Text("\(byAgent[client]?.count ?? 0) from \(client)")
                }
                .foregroundStyle(Color.tmText2)
            }
            Spacer()
            Button("Discard") { confirmDiscard = true }
                .buttonStyle(.secondary)
            if workspace.pending.isEmpty {
                Button {
                    workspace.save()
                } label: {
                    HStack(spacing: 10) {
                        Text(workspace.applying ? String(localized: "Saving…") : saveLabel)
                        Text("⌘S").font(.mono(11)).opacity(0.7)
                    }
                }
                .buttonStyle(.primary)
                .disabled(workspace.applying || workspace.confirmingSave)
            } else {
                Button {
                    workspace.openReview()
                } label: {
                    HStack(spacing: 10) {
                        Text(structure && allSchema ? "Review DDL" : "Review & apply")
                        Text("⌘S").font(.mono(11)).opacity(0.7)
                    }
                }
                .buttonStyle(.primary)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        if mine > 0 && workspace.showChangeList && !workspace.confirmingSave {
            ChangeList(workspace: workspace, agentDDL: structure ? workspace.pending.filter { WorkspaceModel.isDDL($0, dialect: workspace.dialect) } : [])
        }
        if workspace.confirmingSave {
            VStack(alignment: .leading, spacing: 10) {
                SQLSlip(title: "Runs on \(workspace.profile.name)", sql: confirmSQL)
                HStack(spacing: 10) {
                    if let notice = workspace.notice {
                        Text(notice).font(.ui(12)).foregroundStyle(Color.tmBad).lineLimit(2)
                    }
                    Spacer()
                    Button("Cancel") { workspace.confirmingSave = false }.buttonStyle(.secondary)
                    Button(workspace.applying ? "Applying…" : "Apply to production") { Task { await workspace.saveEdits() } }
                        .buttonStyle(.primary)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(workspace.applying)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        } else if let notice = workspace.notice, workspace.pending.isEmpty {
            Text(notice).font(.ui(12)).foregroundStyle(Color.tmBad).lineLimit(2)
                .padding(.horizontal, 14).padding(.bottom, 10)
        }
        }
        .card()
        .animation(.easeOut(duration: 0.15), value: workspace.showChangeList)
        .confirmationDialog(Text(discardTitle), isPresented: $confirmDiscard) {
            if !workspace.staged.isEmpty {
                let edits = workspace.staged.count
                Button(edits == 1 ? String(localized: "Discard your 1 edit") : String(localized: "Discard your \(edits) edits")) { workspace.discardStaged() }
            }
            if !workspace.pending.isEmpty {
                Button("Discard everything, and turn down the agents' proposals", role: .destructive) {
                    Task { await workspace.discardAll() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing has been written yet. Turned-down proposals are marked rejected, and the agent sees that.")
        }
    }

    private var waitingText: String {
        let count = workspace.changeCount
        if structure && allSchema {
            return count == 1 ? String(localized: "1 schema change waiting") : String(localized: "\(count) schema changes waiting")
        }
        return count == 1 ? String(localized: "1 change waiting") : String(localized: "\(count) changes waiting")
    }

    private var discardTitle: String {
        let count = workspace.changeCount
        return count == 1 ? String(localized: "Discard 1 change?") : String(localized: "Discard \(count) changes?")
    }

    /// Every waiting change, yours and the agents', changes structure.
    private var allSchema: Bool {
        workspace.staged.allSatisfy { $0.schemaChange != nil }
            && workspace.pending.allSatisfy { WorkspaceModel.isDDL($0, dialect: workspace.dialect) }
    }

    private var saveLabel: String {
        let mine = workspace.staged.count
        if structure && allSchema && workspace.profile.environment == .production { return String(localized: "Review DDL") }
        return mine == 1 ? String(localized: "Save 1 change") : String(localized: "Save \(mine) changes")
    }

    /// Your edits as they will run; structure changes say what they lock first.
    private var confirmSQL: String {
        workspace.staged.map { change in
            let sql = change.displaySQL(dialect: workspace.dialect) + ";"
            guard let note = change.schemaChange?.localizedLockNote(table: change.table.name, dialect: workspace.dialect) else { return sql }
            return "-- \(note)\n\(sql)"
        }
        .joined(separator: "\n")
    }
}

/// Your staged changes, one line each, with a way to undo any one of them.
private struct ChangeList: View {
    @Bindable var workspace: WorkspaceModel
    /// On the Structure tab, agents' waiting DDL follows yours, in their color.
    var agentDDL: [Proposal] = []

    var body: some View {
        VStack(spacing: 0) {
            Hairline(color: .tmLine2)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(workspace.staged) { change in
                        row(change)
                    }
                    ForEach(agentDDL) { proposal in
                        agentRow(proposal)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 34 * 5 + 8)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ change: RowChange) -> some View {
        let missing = workspace.missingValues(change)
        return HStack(spacing: 10) {
            IconView(icon(change), size: 14).foregroundStyle(Color.tmYou)
            if change.schemaChange != nil {
                // Structure changes read best as the DDL they run.
                Text(change.displaySQL(dialect: workspace.dialect).replacingOccurrences(of: "\n", with: " ") + ";")
                    .font(.mono(12)).foregroundStyle(Color.tmText2).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(change.localizedSummary)
            } else {
                Text(title(change)).font(.ui(13, .semibold)).foregroundStyle(Color.tmText).lineLimit(1).fixedSize()
                Text(detail(change)).font(.mono(12)).foregroundStyle(Color.tmMuted).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !missing.isEmpty {
                Text("\(missing.joined(separator: ", ")) required").font(.ui(12)).foregroundStyle(Color.tmWarn).lineLimit(1)
            } else if case .sql = change.kind, let note = workspace.changeNotes[change.id]?.detail {
                Text(note).font(.ui(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
            }
            Button {
                workspace.unstage(change.id)
            } label: {
                IconView(.undo, size: 14)
            }
            .buttonStyle(QuietButtonStyle(size: 28))
            .help("Undo this change")
            .accessibilityLabel("Undo this change")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
    }

    private func agentRow(_ proposal: Proposal) -> some View {
        Button {
            workspace.openReview(selecting: proposal.id)
        } label: {
            HStack(spacing: 10) {
                Dot(color: .tmAgent, size: 7).frame(width: 14)
                Text(proposal.sql.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(";") ? proposal.sql : proposal.sql + ";")
                    .font(.mono(12)).foregroundStyle(Color.tmAgentText).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(proposal.client)'s proposal; review it to apply")
    }

    private func icon(_ change: RowChange) -> Icon {
        switch change.kind {
        case .insert: .plus
        case .update: .edit
        case .delete: .minus
        case .sql: .braces
        case .schema(let schema):
            switch schema {
            case .addColumn, .addIndex: .plus
            case .alterColumn: .edit
            case .dropColumn, .dropIndex: .minus
            }
        }
    }

    /// "New row", "Copy of 84209", "Edit 84211"; other tables are named.
    private func title(_ change: RowChange) -> String {
        let here = change.table == workspace.currentTable
        let table = change.table.name
        switch change.kind {
        case .insert:
            return workspace.changeNotes[change.id]?.title
                ?? (here ? String(localized: "New row") : String(localized: "New row in \(table)"))
        case .update:
            return here ? String(localized: "Edit \(change.keyLabel)") : String(localized: "Edit \(table) \(change.keyLabel)")
        case .delete:
            return here ? String(localized: "Delete \(change.keyLabel)") : String(localized: "Delete \(table) \(change.keyLabel)")
        case .sql: return here ? "SQL" : String(localized: "SQL on \(table)")
        case .schema(let schema):
            return here ? schema.localizedTitle : String(localized: "\(schema.localizedTitle) on \(table)")
        }
    }

    private func detail(_ change: RowChange) -> String {
        switch change.kind {
        case .insert(let values): values.map { $0.value.displayText }.joined(separator: " · ")
        case .update: change.summary
        case .delete: workspace.changeNotes[change.id]?.detail ?? ""
        case .sql: change.summary
        case .schema: change.displaySQL(dialect: workspace.dialect)
        }
    }
}
