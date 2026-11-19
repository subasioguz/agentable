import AppKit
import SwiftUI
import AgentableCore

/// The SQL tab: run, explain and format on top, the editor, then results, plan and messages.
struct SQLScreen: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var grid: GridModel
    @Bindable var document: SQLDocument
    @Binding var popover: FilterPopover?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                Hairline(color: .tmLine2)
                if let run = document.askRun, run.state != .suggested {
                    AskCard(document: document, run: run)
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                SQLEditorView(document: document, dialect: workspace.dialect)
                    .frame(height: max(170, geometry.size.height * 0.46))
                outputBar
                output
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.tmWindow)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                document.run()
            } label: {
                HStack(spacing: 8) {
                    IconView(.play, size: 12, filled: true)
                    Text("Run")
                    Text("⌘↩").font(.mono(11)).opacity(0.7)
                }
            }
            .buttonStyle(.primary(height: 30))
            .disabled(document.running)
            .help("Run the statement under the cursor, or the selected one")
            Button("Explain") { document.explain() }
                .buttonStyle(.secondary(height: 30))
                .disabled(document.running)
            Button("Format") { document.format() }
                .buttonStyle(.secondary(height: 30))
            Rectangle().fill(Color.tmLine).frame(width: 1, height: 18).padding(.horizontal, 4)
            HStack(spacing: 6) {
                IconView(.lock, size: 14).foregroundStyle(Color.tmMuted)
                Text("Reads run directly. Writes go to review.").font(.ui(12.5)).foregroundStyle(Color.tmText2)
            }
            .lineLimit(1)
            if document.running { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer(minLength: 8)
            if document.file == nil {
                SaveQueryButton(popover: $popover)
            }
            AskButton(document: document, popover: $popover)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: Output

    private var outputBar: some View {
        HStack(spacing: 4) {
            outputTab(.results) {
                HStack(spacing: 6) {
                    Text("Results")
                    if let summary = document.resultSummary {
                        Text(summary).font(.mono(11.5)).foregroundStyle(Color.tmMuted)
                    }
                }
            }
            outputTab(.plan) { Text("Plan") }
            outputTab(.messages) {
                HStack(spacing: 6) {
                    Text("Messages")
                    if document.messages.first?.isError == true { Dot(color: .tmBad, size: 6) }
                }
            }
            Spacer()
            if let result = document.result {
                ResultExportMenu(result: result, table: grid.table, dialect: workspace.dialect)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func outputTab<Label: View>(_ value: SQLDocument.Output, @ViewBuilder label: () -> Label) -> some View {
        let selected = document.output == value
        return Button {
            document.output = value
        } label: {
            label()
                .font(.ui(13, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.tmText : Color.tmMuted)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .overlay(alignment: .bottom) { Rectangle().fill(selected ? Color.tmText : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var output: some View {
        switch document.output {
        case .results:
            if let result = document.result {
                ResultGridView(result: result, revision: document.resultRevision, table: grid.table, dialect: workspace.dialect)
            } else {
                placeholder("No rows yet")
            }
        case .plan:
            if let plan = document.plan {
                ScrollView([.vertical, .horizontal]) {
                    Text(plan)
                        .font(.mono(12))
                        .foregroundStyle(Color.tmText)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            } else {
                placeholder("No plan yet")
            }
        case .messages:
            if document.messages.isEmpty {
                placeholder("No messages")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(document.messages) { message in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(message.at, format: .dateTime.hour().minute().second())
                                    .font(.mono(11.5))
                                    .foregroundStyle(Color.tmMuted)
                                Text(message.text)
                                    .font(.ui(13))
                                    .foregroundStyle(message.isError ? Color.tmBad : Color.tmText2)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) { Hairline(color: .tmLine2) }
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.ui(13))
            .foregroundStyle(Color.tmMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Export" for a query result: copy or save it in one of the export formats.
struct ResultExportMenu: View {
    let result: QueryResult
    let table: TableRef
    let dialect: SQLDialect

    var body: some View {
        Menu {
            Section("Copy as") {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.title) {
                        GridCoordinator.setClipboard(ResultGridCoordinator.text(result, rows: result.rows, format: format, table: table, dialect: dialect))
                    }
                }
            }
            Section("Save as") {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button("\(format.title)…") { save(format) }
                }
            }
        } label: {
            Text("Export")
                .font(.ui(13))
                .foregroundStyle(Color.tmText)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func save(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "result.\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ResultGridCoordinator.text(result, rows: result.rows, format: format, table: table, dialect: dialect)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// "Save…" for a new query; opens a small panel that asks for its name.
struct SaveQueryButton: View {
    @Binding var popover: FilterPopover?
    @State private var frame = CGRect.zero

    var body: some View {
        Button("Save…") {
            popover = popover?.kind == .saveQuery ? nil : FilterPopover(kind: .saveQuery, anchor: frame)
        }
        .buttonStyle(.secondary(height: 30))
        .help("Save this query for this connection")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FilterPopover.space)) } action: { frame = $0 }
    }
}

/// Asks for a query's name and saves it.
struct SaveQueryPanel: View {
    let document: SQLDocument
    let onDone: () -> Void
    @State private var name = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save query").font(.ui(13, .semibold)).foregroundStyle(Color.tmText)
            FieldBox(height: 32) {
                TextField("charged-twice", text: $name)
                    .textFieldStyle(.plain)
                    .font(.mono(12.5))
                    .focused($focused)
                    .onSubmit(save)
                Text(".sql").font(.mono(12.5)).foregroundStyle(Color.tmMuted)
            }
            HStack {
                if let problem {
                    Text(problem).font(.ui(12)).foregroundStyle(Color.tmBad).lineLimit(2)
                }
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.primary(height: 28))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { focused = true }
    }

    private func save() {
        do {
            try document.save(named: name)
            onDone()
        } catch {
            problem = "\(error)"
        }
    }
}
