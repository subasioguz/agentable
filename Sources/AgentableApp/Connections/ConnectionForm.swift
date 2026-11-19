import AppKit
import SwiftUI
import AgentableCore

/// The fields of a connection being added or edited.
struct ConnectionDraft: Identifiable {
    let id = UUID()
    var original: ConnectionProfile?
    var url = ""
    var name = ""
    var engine: DatabaseEngine = .postgres
    var environment: DeploymentEnvironment = .local
    var host = ""
    var port = ""
    var user = ""
    var database = ""
    var password = ""
    var tls: TLSMode = .prefer
    var caFile = ""
    var clientCertificate = ""
    var clientKey = ""
    var sshOn = false
    var sshHost = ""
    var sshUser = ""
    var sshPort = ""
    var sshKey = ""
    /// `nil` follows the environment's default.
    var access: AgentAccess?

    init() {}

    init(_ profile: ConnectionProfile) {
        original = profile
        name = profile.name
        engine = profile.engine
        environment = profile.environment
        host = profile.host ?? ""
        port = profile.port.map(String.init) ?? ""
        user = profile.user ?? ""
        database = profile.database ?? ""
        tls = profile.tls
        caFile = profile.tlsFiles?.rootCertificate ?? ""
        clientCertificate = profile.tlsFiles?.clientCertificate ?? ""
        clientKey = profile.tlsFiles?.clientKey ?? ""
        sshOn = profile.ssh != nil
        sshHost = profile.ssh?.host ?? ""
        sshUser = profile.ssh?.user ?? ""
        sshPort = profile.ssh?.port.map(String.init) ?? ""
        sshKey = profile.ssh?.identityFile ?? ""
        access = profile.agentAccess
    }

    var nameIsValid: Bool { ConnectionProfile.isValidName(name) }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The profile these fields describe, keeping everything the form does not show.
    var profile: ConnectionProfile {
        var profile = original ?? ConnectionProfile(name: name, engine: engine, environment: environment)
        profile.name = name
        profile.engine = engine
        profile.environment = environment
        profile.host = engine == .sqlite || host.isEmpty ? nil : host
        profile.port = engine == .sqlite ? nil : Int(port)
        profile.user = engine == .sqlite || user.isEmpty ? nil : user
        profile.database = database.isEmpty ? nil : database
        profile.tls = engine == .sqlite ? .disable : tls
        let files = TLSFiles(rootCertificate: Self.text(caFile), clientCertificate: Self.text(clientCertificate), clientKey: Self.text(clientKey))
        profile.tlsFiles = engine == .sqlite || tls == .disable || files.isEmpty ? nil : files
        profile.ssh = engine == .sqlite || !sshOn || sshHost.trimmingCharacters(in: .whitespaces).isEmpty ? nil
            : SSHSettings(host: sshHost.trimmingCharacters(in: .whitespaces), port: Int(sshPort), user: Self.text(sshUser), identityFile: Self.text(sshKey))
        profile.agentAccess = access
        return profile
    }

    /// Fills the fields from a pasted URL or path. Returns false when the text is not one.
    mutating func apply(url text: String) -> Bool {
        guard let parsed = try? ConnectionURL.parse(text, name: name.isEmpty ? "new" : name, environment: environment) else {
            return false
        }
        let profile = parsed.profile
        engine = profile.engine
        host = profile.host ?? ""
        port = profile.port.map(String.init) ?? ""
        user = profile.user ?? ""
        database = profile.database ?? ""
        tls = profile.tls
        if let password = parsed.password { self.password = password }
        if name.isEmpty {
            let base = engine == .sqlite ? ((database as NSString).lastPathComponent as NSString).deletingPathExtension : (database.isEmpty ? host : database)
            let cleaned = base.lowercased().map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" }
            name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        }
        return true
    }
}

struct ConnectionForm: View {
    @Environment(AppModel.self) private var app
    @State var draft: ConnectionDraft
    let onClose: () -> Void

    @State private var urlFilled = false
    @State private var testResult: Result<Duration, Error>?
    @State private var testing = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(draft.original == nil ? "New connection" : "Edit \(draft.original?.name ?? "")")
                    .font(.ui(17, .semibold))
                    .tracking(-0.17)
                Spacer()
                Button(action: onClose) {
                    IconView(.close, size: 15)
                }
                .buttonStyle(.quiet)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if draft.original == nil {
                        field("Paste a URL or a SQLite file path") {
                            TextField("postgres://user@host:5432/db", text: $draft.url)
                                .font(.mono(12.5))
                                .onChange(of: draft.url) { _, text in
                                    urlFilled = draft.apply(url: text)
                                }
                        }
                        if urlFilled {
                            Label(draft.engine == .sqlite ? "Filled the file path below" : "Filled host, port, user and database below", systemImage: "checkmark")
                                .font(.ui(12))
                                .foregroundStyle(Color.tmOK)
                                .padding(.top, -10)
                        }
                    }

                    field("Name") {
                        TextField("acme-dev", text: $draft.name)
                    }
                    if !draft.name.isEmpty && !draft.nameIsValid {
                        Text("Lower-case letters, digits, - _ and . only. Agents address the connection by this name.")
                            .font(.ui(12)).foregroundStyle(Color.tmBad).padding(.top, -10)
                    }

                    environmentPicker

                    if draft.engine == .sqlite {
                        field("File") {
                            TextField("~/data/app.sqlite", text: $draft.database).font(.mono(12.5))
                            Button("Choose…") { chooseFile() }.buttonStyle(.secondary(height: 26))
                        }
                    } else {
                        HStack(spacing: 10) {
                            field("Host") { TextField("localhost", text: $draft.host).font(.mono(12.5)) }
                            field("Port") { TextField("5432", text: $draft.port).font(.mono(12.5)) }.frame(width: 90)
                        }
                        HStack(spacing: 10) {
                            field("User") { TextField(NSUserName(), text: $draft.user).font(.mono(12.5)) }
                            field("Database") { TextField("postgres", text: $draft.database).font(.mono(12.5)) }
                        }
                        field("Password") {
                            SecureField(draft.original == nil ? "" : "Saved in Keychain", text: $draft.password).font(.mono(12.5))
                        }
                        Text("Saved to Keychain. Agents never receive it.")
                            .font(.ui(12)).foregroundStyle(Color.tmMuted).padding(.top, -10)
                        sshSection
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TLS").font(.ui(12, .medium)).foregroundStyle(Color.tmText2)
                            SegmentedSwitch(
                                options: [(.disable, String(localized: "Off")), (.prefer, String(localized: "Prefer")),
                                          (.require, String(localized: "Require")), (.verifyFull, String(localized: "Verify"))],
                                selection: $draft.tls, height: 26, fill: true
                            )
                        }
                        if draft.tls == .require || draft.tls == .verifyFull {
                            fileField("CA certificate", text: $draft.caFile, placeholder: draft.tls == .verifyFull ? "System roots" : "Not checked")
                            HStack(spacing: 10) {
                                fileField("Client certificate", text: $draft.clientCertificate, placeholder: "None")
                                fileField("Client key", text: $draft.clientKey, placeholder: "None")
                            }
                        }
                    }

                    agentAccess
                }
                .textFieldStyle(.plain)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            if let error {
                Text(error).font(.ui(12)).foregroundStyle(Color.tmBad).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                testStatus
                Spacer()
                Button(testing ? "Testing…" : (testResult == nil ? "Test" : "Test again")) { Task { await test() } }
                    .buttonStyle(.secondary)
                    .disabled(testing)
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.primary)
                    .disabled(!draft.nameIsValid || saving)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { urlFilled = !draft.url.isEmpty }
    }

    /// "SSH tunnel" with a switch, as drawn; the server's fields open under it.
    private var sshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SSH tunnel").font(.ui(13, .medium)).foregroundStyle(Color.tmText)
                    Text(sshSummary).font(.mono(12)).foregroundStyle(Color.tmMuted).lineLimit(1)
                }
                Spacer()
                ToggleSwitch(isOn: $draft.sshOn)
            }
            if draft.sshOn {
                HStack(spacing: 10) {
                    field("SSH host") { TextField("bastion or a ~/.ssh/config name", text: $draft.sshHost).font(.mono(12.5)) }
                    field("Port") { TextField("22", text: $draft.sshPort).font(.mono(12.5)) }.frame(width: 86)
                }
                HStack(spacing: 10) {
                    field("SSH user") { TextField("from ~/.ssh/config", text: $draft.sshUser).font(.mono(12.5)) }
                    fileField("Key", text: $draft.sshKey, placeholder: "SSH agent", startIn: ".ssh")
                }
                Text("Uses your SSH agent, ~/.ssh/config and known_hosts. Agents never see it.")
                    .font(.ui(12)).foregroundStyle(Color.tmMuted).padding(.top, -4)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Hairline(color: .tmLine2) }
        .onAppear {
            // The new-connection snapshot shows the tunnel as drawn.
            if Snapshot.isActive, Snapshot.scene == "new-connection", draft.original == nil {
                draft.sshOn = true
                draft.sshHost = "bastion-eu-1"
                draft.sshKey = "~/.ssh/id_ed25519"
            }
        }
    }

    private var sshSummary: String {
        let host = draft.sshHost.trimmingCharacters(in: .whitespaces)
        guard draft.sshOn, !host.isEmpty else { return String(localized: "Off") }
        return SSHSettings(host: host, port: Int(draft.sshPort), user: draft.sshUser.isEmpty ? nil : draft.sshUser,
                           identityFile: draft.sshKey.isEmpty ? nil : draft.sshKey).summary
    }

    /// A path field with "Choose…", for keys and certificates.
    private func fileField(_ label: LocalizedStringKey, text: Binding<String>, placeholder: LocalizedStringKey, startIn folder: String = "") -> some View {
        field(label) {
            TextField(placeholder, text: text).font(.mono(12.5))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.showsHiddenFiles = true
                panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: folder)
                if panel.runModal() == .OK, let url = panel.url {
                    text.wrappedValue = (url.path as NSString).abbreviatingWithTildeInPath
                }
            }
            .buttonStyle(.text(height: 24, size: 12))
        }
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ui(12, .medium)).foregroundStyle(Color.tmText2)
            FieldBox(height: 36) { content() }
        }
    }

    private var environmentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Environment").font(.ui(12, .medium)).foregroundStyle(Color.tmText2)
            HStack(spacing: 3) {
                ForEach(DeploymentEnvironment.allCases, id: \.self) { environment in
                    let selected = draft.environment == environment
                    Button {
                        draft.environment = environment
                        if let access = draft.access, access > environment.maximumAgentAccess { draft.access = environment.maximumAgentAccess }
                    } label: {
                        HStack(spacing: 6) {
                            Dot(color: environment.dotColor, size: 6)
                            Text(environment.title).font(.ui(13, selected ? .semibold : .regular))
                        }
                        .foregroundStyle(selected ? Color.tmText : Color.tmText2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7).fill(Color.tmWindow)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.tmLine))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.tmChip, in: RoundedRectangle(cornerRadius: 10))
            Text(environmentNote).font(.ui(12)).foregroundStyle(Color.tmMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var environmentNote: String {
        switch draft.environment {
        case .production: String(localized: "Production gets review before every write, and agents start at Read.")
        case .staging: String(localized: "Agents start at Propose: their changes wait for you.")
        case .dev, .local: String(localized: "Agents start at Write.")
        }
    }

    /// A sentence continued after a colon: its first letter in lower case, except in German, where
    /// nouns keep their capital.
    private static func continuing(_ sentence: String) -> String {
        guard L10n.language != "de", let first = sentence.first else { return sentence }
        return String(first).lowercased(with: L10n.locale) + sentence.dropFirst()
    }

    private var agentAccess: some View {
        let effective = draft.profile.effectiveAgentAccess
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent access").font(.ui(13, .medium))
                Text(draft.access == nil
                     ? "\(effective.label.capitalized(with: L10n.locale)), the \(draft.environment.rawValue) default"
                     : "\(effective.label.capitalized(with: L10n.locale)): \(Self.continuing(accessNote(effective)))")
                    .font(.ui(12)).foregroundStyle(Color.tmMuted)
            }
            Spacer()
            Menu {
                Button("Environment default (\(draft.environment.defaultAgentAccess.label))") { draft.access = nil }
                Divider()
                ForEach(AgentAccess.allCases, id: \.self) { level in
                    Button(level.label.capitalized(with: L10n.locale)) { draft.access = level }
                        .disabled(level > draft.environment.maximumAgentAccess)
                }
            } label: {
                Text("Change").font(.ui(12.5)).foregroundStyle(Color.tmYou)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Hairline(color: .tmLine2) }
    }

    private func accessNote(_ access: AgentAccess) -> String {
        switch access {
        case .off: String(localized: "Agents cannot see this connection")
        case .read: String(localized: "Schema and read-only queries")
        case .propose: String(localized: "Reads, and changes that wait for you")
        case .write: String(localized: "Reads and writes directly")
        }
    }

    @ViewBuilder private var testStatus: some View {
        switch testResult {
        case .success(let elapsed)?:
            Label("Connected · \(Int((Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * 1000)) ms", systemImage: "checkmark")
                .font(.ui(12)).foregroundStyle(Color.tmOK)
        case .failure(let error)?:
            Text(String(describing: error)).font(.ui(12)).foregroundStyle(Color.tmBad).lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a SQLite database file")
        if panel.runModal() == .OK, let url = panel.url {
            draft.database = url.path
            if draft.name.isEmpty { _ = draft.apply(url: url.path) }
        }
    }

    private func test() async {
        testing = true
        let password: String? = draft.password.isEmpty ? (draft.original.flatMap { try? app.secrets.password(for: $0.id) }) : draft.password
        testResult = await app.test(draft.profile, password: password)
        testing = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if draft.original == nil, app.profiles.contains(where: { $0.name == draft.name }) {
            error = String(localized: "There is already a connection named \(draft.name).")
            return
        }
        do {
            let password: String? = draft.engine == .sqlite ? nil : (draft.original == nil || !draft.password.isEmpty ? draft.password : nil)
            try await app.save(draft.profile, password: password, replacing: draft.original)
            onClose()
        } catch {
            self.error = "\(error)"
        }
    }
}
