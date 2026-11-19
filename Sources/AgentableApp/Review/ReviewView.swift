import SwiftUI
import AgentableCore

/// Everything waiting on this connection, yours and the agents', applied together in one transaction.
struct ReviewView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var note = ""
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if workspace.changeCount == 0 {
                VStack(spacing: 8) {
                    Text("Nothing waiting").font(.ui(15, .semibold))
                    Text("Edit a cell, or let an agent propose a change, and it shows up here before anything is written.")
                        .foregroundStyle(Color.tmMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ChangeList(workspace: workspace)
                        .frame(width: 280)
                    Hairline(vertical: true)
                    ScrollView {
                        detail
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .padding(.bottom, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
                actionBar
            }
        }
        .background(Color.tmWindow)
        .onAppear(perform: ensureSelection)
        .onChange(of: workspace.changeCount) { ensureSelection() }
        .confirmationDialog("Discard all \(workspace.changeCount) changes?", isPresented: $confirmDiscard) {
            Button("Discard all", role: .destructive) { Task { await workspace.discardAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits are dropped and the agents' proposals are turned down. Nothing was written.")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let back = workspace.tabs.last(where: { $0 != .review }), case .table(let table) = back {
                    Button {
                        workspace.selected = back
                    } label: {
                        Label(table.name, systemImage: "chevron.left").font(.ui(12.5)).foregroundStyle(Color.tmMuted)
                    }
                    .buttonStyle(.plain)
                }
                Text(workspace.changeCount == 1 ? String(localized: "Review 1 change") : String(localized: "Review \(workspace.changeCount) changes"))
                    .font(.ui(24, .semibold)).tracking(-0.48)
                Text("They apply together in one transaction. Nothing is written until you apply.")
                    .foregroundStyle(Color.tmMuted)
            }
            Spacer()
            if workspace.changeCount > 0 {
                Button("Discard all") { confirmDiscard = true }.buttonStyle(.secondary(height: 34))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Hairline() }
    }

    @ViewBuilder private var detail: some View {
        if let id = workspace.reviewSelection, let proposal = workspace.pending.first(where: { $0.id == id }) {
            ProposalDetail(workspace: workspace, proposal: proposal)
                .id(proposal.id)
        } else if let id = workspace.reviewSelection, let change = workspace.staged.first(where: { $0.id.uuidString == id }) {
            EditDetail(workspace: workspace, change: change)
        }
    }

    private var selectedProposal: Proposal? {
        workspace.reviewSelection.flatMap { id in workspace.pending.first { $0.id == id } }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let proposal = selectedProposal {
                FieldBox(height: 38) {
                    Avatar(kind: .agent, size: 20)
                    TextField("Note for \(proposal.client) if you turn it down (optional)", text: $note)
                        .textFieldStyle(.plain)
                }
                Button("Reject proposal") {
                    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    note = ""
                    Task { await workspace.reject(proposal, note: text.isEmpty ? nil : text) }
                }
                .buttonStyle(.secondary(height: 38))
            } else {
                if let notice = workspace.notice {
                    Text(notice).font(.ui(12)).foregroundStyle(Color.tmBad).lineLimit(2)
                }
                Spacer()
            }
            Button {
                Task { await workspace.applyIncluded() }
            } label: {
                HStack(spacing: 10) {
                    Text(applyLabel)
                    Text("⌘↩").font(.mono(11)).opacity(0.7)
                }
            }
            .buttonStyle(.primary(height: 38))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(workspace.includedCount == 0 || workspace.applying)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .topLeading) {
            if selectedProposal != nil, let notice = workspace.notice {
                Text(notice).font(.ui(12)).foregroundStyle(Color.tmBad)
                    .padding(.horizontal, 22).offset(y: -22)
            }
        }
    }

    private var applyLabel: String {
        if workspace.applying { return String(localized: "Applying…") }
        let count = workspace.includedCount
        return count == 1 ? String(localized: "Apply 1 change") : String(localized: "Apply \(count) changes")
    }

    private func ensureSelection() {
        let ids = workspace.staged.map(\.id.uuidString) + workspace.pending.map(\.id)
        if workspace.reviewSelection == nil || !ids.contains(workspace.reviewSelection!) {
            workspace.reviewSelection = workspace.pending.first?.id ?? workspace.staged.first?.id.uuidString
        }
    }
}

/// Left column: your edits, then each agent's proposals, each with a tick to leave it out.
private struct ChangeList: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !workspace.staged.isEmpty {
                        groupLabel(String(localized: "You"), color: .tmYou)
                        ForEach(workspace.staged) { change in
                            item(id: change.id.uuidString, color: .tmYou, title: title(of: change), subtitle: change.localizedSummary)
                        }
                    }
                    let clients = Array(Set(workspace.pending.map(\.client))).sorted()
                    ForEach(clients, id: \.self) { client in
                        groupLabel(client, color: .tmAgent).padding(.top, workspace.staged.isEmpty && client == clients.first ? 0 : 10)
                        ForEach(workspace.pending.filter { $0.client == client }) { proposal in
                            item(id: proposal.id, color: .tmAgent, title: ProposalText.title(proposal), subtitle: ProposalText.subtitle(proposal))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            summary
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.tmSide)
    }

    private func title(of change: RowChange) -> String {
        switch change.kind {
        case .update: String(localized: "Edit \(change.table.name) \(change.keyLabel)")
        case .delete: String(localized: "Delete \(change.table.name) \(change.keyLabel)")
        case .insert: String(localized: "New row in \(change.table.name)")
        case .sql: String(localized: "SQL on \(change.table.name)")
        case .schema(let schema): String(localized: "\(schema.localizedTitle) on \(change.table.name)")
        }
    }

    private func groupLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Dot(color: color)
            SectionLabel(verbatim: text)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func item(id: String, color: Color, title: String, subtitle: String) -> some View {
        let selected = workspace.reviewSelection == id
        let included = !workspace.excluded.contains(id)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                if included { workspace.excluded.insert(id) } else { workspace.excluded.remove(id) }
            } label: {
                CheckBox(on: included, color: color, size: 20, radius: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(included ? "Leave out of this apply" : "Include in this apply")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(13, .semibold)).foregroundStyle(included ? Color.tmText : Color.tmMuted)
                Text(subtitle).font(.mono(12)).foregroundStyle(Color.tmMuted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10).fill(Color.tmWindow)
                    .shadow(color: Color.tmShadow.opacity(0.35), radius: 8, y: 6)
            }
        }
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 10).strokeBorder(color) }
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.reviewSelection = id }
    }

    private var summary: some View {
        let edits = workspace.staged.filter { !workspace.excluded.contains($0.id.uuidString) }
        let proposals = workspace.pending.filter { !workspace.excluded.contains($0.id) }
        let rows = edits.count + proposals.compactMap(\.dryRunRows).reduce(0, +)
        let tables = Set(edits.map(\.table.name) + proposals.compactMap { $0.preview?.table })
        let profile = workspace.profile
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Applying")
            Text(Self.rowsText(rows, in: tables.sorted().joined(separator: ", ")))
            Text("in one transaction on \(profile.name)")
            if let agentUser = profile.agentUser {
                Text("as \(profile.user ?? String(localized: "you")), not as \(agentUser)")
            } else {
                Text("with your own credentials")
            }
        }
        .font(.ui(12.5))
        .foregroundStyle(Color.tmText2)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }

    /// "3 rows in orders, customers"
    private static func rowsText(_ rows: Int, in tables: String) -> String {
        if tables.isEmpty {
            return rows == 1 ? String(localized: "1 row") : String(localized: "\(rows) rows")
        }
        return rows == 1 ? String(localized: "1 row in \(tables)") : String(localized: "\(rows) rows in \(tables)")
    }
}

enum ProposalText {
    /// "Update 3 rows in orders"
    static func title(_ proposal: Proposal) -> String {
        let verb = proposal.sql.split(separator: " ").first.map { $0.uppercased() } ?? ""
        let rows = proposal.dryRunRows.map { $0 == 1 ? String(localized: "1 row") : String(localized: "\($0) rows") }
            ?? String(localized: "proposal.rows", defaultValue: "rows")
        let table = proposal.preview?.table ?? SQLAnalyzer.writeTarget(of: proposal.sql, dialect: .postgres)?.name
        let keyword = verb.lowercased()
        switch (verb, table) {
        case ("UPDATE", let table?): return String(localized: "Update \(rows) in \(table)")
        case ("UPDATE", nil): return String(localized: "Update \(rows)")
        case ("DELETE", let table?): return String(localized: "Delete \(rows) in \(table)")
        case ("DELETE", nil): return String(localized: "Delete \(rows)")
        case ("INSERT", let table?): return String(localized: "Add \(rows) in \(table)")
        case ("INSERT", nil): return String(localized: "Add \(rows)")
        case ("CREATE", let table?), ("ALTER", let table?), ("DROP", let table?):
            return String(localized: "Change the schema: \(keyword) in \(table)")
        case ("CREATE", nil), ("ALTER", nil), ("DROP", nil):
            return String(localized: "Change the schema: \(keyword)")
        case (_, let table?): return String(localized: "Run \(keyword) in \(table)")
        case (_, nil): return String(localized: "Run \(keyword)")
        }
    }

    static func subtitle(_ proposal: Proposal) -> String {
        if let preview = proposal.preview, let index = preview.columns.firstIndex(where: { $0 == "id" }) {
            let ids = preview.rows.prefix(3).compactMap { $0[index] }
            return ids.joined(separator: " · ") + (preview.rows.count > 3 ? " · …" : "")
        }
        return String(proposal.sql.prefix(80))
    }
}

/// An agent's proposal: who, why, which rows change and how, what the trial run showed, the SQL.
private struct ProposalDetail: View {
    @Bindable var workspace: WorkspaceModel
    let proposal: Proposal
    @State private var current: [String: [String: String?]] = [:]
    @State private var showSQL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(kind: .agent, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(proposal.client).font(.ui(13, .semibold))
                        Text("proposed at \(L10n.time(proposal.createdAt))").foregroundStyle(Color.tmMuted)
                    }
                    Text("Waiting for you on \(proposal.connection)").foregroundStyle(Color.tmText2)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(ProposalText.title(proposal)).font(.ui(20, .semibold)).tracking(-0.3)
                if let reason = proposal.reason {
                    (Text("Agent's note: ").foregroundStyle(Color.tmMuted) + Text(reason).foregroundStyle(Color.tmText2))
                        .frame(maxWidth: 680, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let preview = proposal.preview, !preview.rows.isEmpty {
                PreviewTable(preview: preview, current: current)
            }

            checks

            DisclosureSlip(sql: proposal.sql, expanded: $showSQL)

            HStack(spacing: 8) {
                IconView(.arrowRight, size: 13)
                Text("After you decide, \(proposal.client) sees the result the next time it checks its proposals.")
            }
            .foregroundStyle(Color.tmMuted)
        }
        .task { await loadCurrent() }
    }

    private var checks: some View {
        FlowLayout(spacing: 20, lineSpacing: 8) {
            if let rows = proposal.dryRunRows {
                check(rows == 1 ? "Trial run changed 1 row" : "Trial run changed \(rows) rows", ok: true)
            }
            check("Rolled back after the trial", ok: true)
            if proposal.preview?.truncated == true {
                check("Showing the first \(proposal.preview?.rows.count ?? 0)", ok: false)
            }
            if workspace.profile.environment == .production {
                check("Applies to production", ok: false)
            }
        }
    }

    private func check(_ text: String.LocalizationValue, ok: Bool) -> some View {
        HStack(spacing: 8) {
            IconView(ok ? .check : .warning, size: 15, weight: 2)
                .foregroundStyle(ok ? Color.tmOK : Color.tmWarn)
            Text(String(localized: text)).foregroundStyle(Color.tmText2)
        }
        .fixedSize()
    }

    /// Current values of the rows the proposal touches, so the table can show what each becomes.
    private func loadCurrent() async {
        guard let preview = proposal.preview, preview.kind == .update, let browser = workspace.browser else { return }
        let table = TableRef(schema: preview.schema, name: preview.table)
        guard let description = await workspace.describe(table) else { return }
        let keys = description.columns.filter(\.primaryKey).map(\.name)
        guard keys.count == 1, let keyIndex = preview.columns.firstIndex(of: keys[0]) else { return }
        let values = preview.rows.compactMap { $0[keyIndex] }.map { CellValue.text($0) }
        guard !values.isEmpty else { return }
        var filter = TableFilter()
        filter.append(FilterCondition(column: keys[0], category: .text, op: .isAnyOf, values: values))
        let query = TableQuery(table: table, dialect: workspace.dialect, filter: filter, primaryKey: keys)
        guard let result = try? await browser.page(query, offset: 0, limit: 200) else { return }
        let names = result.columns.map(\.name)
        guard let index = names.firstIndex(of: keys[0]) else { return }
        var rows: [String: [String: String?]] = [:]
        for row in result.rows {
            var mapped: [String: String?] = [:]
            for (position, name) in names.enumerated() { mapped[name] = row[position].isNull ? nil : row[position].displayText }
            rows[row[index].displayText] = mapped
        }
        current = rows
    }
}

/// The rows a proposal changes: key columns, then each changed column as "was → new".
private struct PreviewTable: View {
    let preview: ProposalPreview
    let current: [String: [String: String?]]

    var body: some View {
        let keyIndex = preview.columns.firstIndex(of: "id") ?? 0
        let changed = changedColumns(keyIndex: keyIndex)
        let shown = [keyIndex] + changed
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(shown, id: \.self) { index in
                    Text(preview.columns[index]).font(.ui(12, .semibold)).foregroundStyle(Color.tmText2)
                        .padding(.horizontal, 12)
                        .frame(width: index == keyIndex ? 110 : nil, alignment: .leading)
                        .frame(maxWidth: index == keyIndex ? nil : .infinity, alignment: .leading)
                }
            }
            .frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            ForEach(Array(preview.rows.prefix(50).enumerated()), id: \.offset) { position, row in
                let key = row[keyIndex] ?? ""
                HStack(spacing: 0) {
                    ForEach(shown, id: \.self) { index in
                        Group {
                            if index == keyIndex {
                                Text(key).font(.mono(12.5))
                            } else {
                                change(was: current[key]?[preview.columns[index]] ?? nil, now: row[index], kind: preview.kind)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(width: index == keyIndex ? 110 : nil, alignment: .leading)
                        .frame(maxWidth: index == keyIndex ? nil : .infinity, alignment: .leading)
                    }
                }
                .frame(height: 40)
                .overlay(alignment: .bottom) {
                    if position < min(preview.rows.count, 50) - 1 { Hairline(color: .tmLine2) }
                }
            }
        }
        .background(Color.tmWindow)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.tmLine))
    }

    /// Columns whose new value differs from the current one (all columns until current values load).
    private func changedColumns(keyIndex: Int) -> [Int] {
        let candidates = preview.columns.indices.filter { $0 != keyIndex }
        guard preview.kind == .update, !current.isEmpty else { return Array(candidates.prefix(3)) }
        let changed = candidates.filter { index in
            preview.rows.contains { row in
                guard let key = row[keyIndex], let now = current[key] else { return false }
                return (now[preview.columns[index]] ?? nil) != row[index]
            }
        }
        return changed.isEmpty ? Array(candidates.prefix(3)) : Array(changed.prefix(4))
    }

    @ViewBuilder private func change(was: String?, now: String?, kind: ProposalPreview.Kind) -> some View {
        HStack(spacing: 6) {
            if kind == .update, let was, was != now {
                Text(was).strikethrough().foregroundStyle(Color.tmMuted).lineLimit(1)
            }
            if kind == .delete {
                Text(now ?? "NULL").strikethrough().foregroundStyle(Color.tmMuted).lineLimit(1)
            } else if kind == .update, was == now {
                Text(now ?? "NULL").foregroundStyle(Color.tmText2).lineLimit(1)
            } else {
                Text(now ?? "NULL")
                    .font(.mono(12.5, .medium))
                    .foregroundStyle(Color.tmAgentText)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.tmAgent, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
        }
        .font(.mono(12.5))
    }
}

/// One of your staged edits.
private struct EditDetail: View {
    @Bindable var workspace: WorkspaceModel
    let change: RowChange
    @State private var showSQL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(kind: .you, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You").font(.ui(13, .semibold))
                    Text("edited at \(L10n.time(change.createdAt))").foregroundStyle(Color.tmMuted)
                }
            }
            Text(headline).font(.ui(20, .semibold)).tracking(-0.3)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    cellHeader(String(localized: "column")).frame(width: 160, alignment: .leading)
                    cellHeader(String(localized: "review.was", defaultValue: "was")).frame(maxWidth: .infinity, alignment: .leading)
                    cellHeader(String(localized: "review.now", defaultValue: "now")).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 34)
                .overlay(alignment: .bottom) { Hairline() }
                switch change.kind {
                case .update(let columns):
                    ForEach(columns, id: \.column) { item in
                        HStack(spacing: 0) {
                            Text(item.column).font(.mono(12.5)).lineLimit(1).padding(.horizontal, 12).frame(width: 160, alignment: .leading)
                            Text(item.old.displayText).font(.mono(12.5)).strikethrough().foregroundStyle(Color.tmMuted)
                                .lineLimit(1).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.new.displayText).font(.mono(12.5)).foregroundStyle(item.new.isNull ? Color.tmMuted : Color.tmText)
                                .lineLimit(1).padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .background(Color.tmYouTint)
                        }
                        .frame(height: 40)
                    }
                case .delete:
                    Text("The whole row is deleted.").padding(12).frame(maxWidth: .infinity, alignment: .leading)
                case .sql:
                    Text(workspace.changeNotes[change.id]?.detail.map { String(localized: "Runs as written. The trial run said it \($0).") }
                         ?? String(localized: "Runs as written."))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                case .schema(let schema):
                    Text(schema.localizedLockNote(table: change.table.name, dialect: workspace.dialect) ?? String(localized: "Changes the table's structure."))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                case .insert(let values):
                    ForEach(values, id: \.column) { item in
                        HStack(spacing: 0) {
                            Text(item.column).font(.mono(12.5)).lineLimit(1).padding(.horizontal, 12).frame(width: 160, alignment: .leading)
                            Text("").frame(maxWidth: .infinity)
                            Text(item.value.displayText).font(.mono(12.5)).foregroundStyle(item.value.isNull ? Color.tmMuted : Color.tmText)
                                .lineLimit(1).padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .background(Color.tmYouTint)
                        }
                        .frame(height: 40)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.tmLine))

            DisclosureSlip(sql: change.displaySQL(dialect: workspace.dialect), expanded: $showSQL)

            Button("Undo this edit") { workspace.unstage(change.id) }.buttonStyle(.secondary)
        }
    }

    private var headline: String {
        switch change.kind {
        case .update(let columns):
            String(localized: "Edit \(change.table.name) \(change.keyLabel)") + " · "
                + (columns.count == 1 ? String(localized: "1 column") : String(localized: "\(columns.count) columns"))
        case .delete: String(localized: "Delete \(change.table.name) \(change.keyLabel)")
        case .insert(let values):
            String(localized: "New row in \(change.table.name)") + " · "
                + (values.count == 1 ? String(localized: "1 value") : String(localized: "\(values.count) values"))
        case .sql: String(localized: "SQL on \(change.table.name)")
        case .schema(let schema): String(localized: "\(schema.localizedTitle) on \(change.table.name)")
        }
    }

    private func cellHeader(_ text: String) -> some View {
        Text(text).font(.ui(12, .semibold)).foregroundStyle(Color.tmText2).padding(.horizontal, 12)
    }
}

/// A one-line SQL strip that opens into the full slip.
struct DisclosureSlip: View {
    let sql: String
    @Binding var expanded: Bool

    var body: some View {
        if expanded {
            SQLSlip(title: "SQL", sql: sql) { expanded = false }
        } else {
            Button {
                expanded = true
            } label: {
                HStack(spacing: 12) {
                    SectionLabel(text: "SQL")
                    Text(sql.replacingOccurrences(of: "\n", with: " "))
                        .font(.mono(12))
                        .foregroundStyle(Color.tmText2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconView(.chevronDown, size: 13, weight: 2).foregroundStyle(Color.tmMuted)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Color.tmSide, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.tmLine))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show SQL")
        }
    }
}
