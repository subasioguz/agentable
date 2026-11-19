import Foundation

/// What an agent gets back for a query.
public enum AgentOutcome: Sendable {
    case result(AgentResult)
    case proposed(Proposal)
    case denied(String)
}

public struct AgentResult: Sendable {
    public var connection: String
    public var result: QueryResult
    /// Names of result columns whose values were masked.
    public var maskedColumns: [String]
    public var readOnly: Bool
}

/// A table or column that matched a schema search.
public struct SchemaMatch: Sendable, Hashable, Codable {
    public var table: String
    public var column: String?
    public var type: String?
}

/// The agent's door: every agent request (CLI today, MCP next) goes through here. It applies the
/// connection's policy, opens sessions with the stored credentials, masks results and logs everything.
public struct AgentGateway: Sendable {
    public let profiles: ProfileStore
    public let secrets: any SecretStore
    public let state: StateStore
    public let sessions: any SessionFactory

    public init(profiles: ProfileStore, secrets: any SecretStore, state: StateStore, sessions: any SessionFactory) {
        self.profiles = profiles
        self.secrets = secrets
        self.state = state
        self.sessions = sessions
    }

    /// Connections agents may see, with their access level.
    public func connections() throws -> [ConnectionProfile] {
        try profiles.load().filter { $0.effectiveAgentAccess != .off }
    }

    public func query(connection name: String, sql: String, client: String) async throws -> AgentOutcome {
        let profile = try visibleProfile(named: name)

        switch AgentPolicy.evaluate(sql, on: profile) {
        case .deny(let reason):
            try await state.record(AuditEvent(connection: name, client: client, action: .denied, sql: sql, detail: reason))
            return .denied(reason)

        case .propose(let statement):
            return .proposed(try await file(statement.text, reason: nil, on: profile, client: client))

        case .run(let statement, let readOnly):
            let session = readOnly
                ? try await agentSession(profile)
                : try await sessions.open(profile, password: try secrets.password(for: profile.id), readOnly: false)
            do {
                var result = try await session.run(
                    statement.text,
                    options: QueryOptions(
                        readOnly: readOnly,
                        maxRows: profile.limits.maxRows,
                        timeout: .seconds(profile.limits.timeoutSeconds)
                    )
                )
                await session.close()
                let masked = Masking.columnsToMask(result.columns, rules: profile.rules, mentioned: statement.identifiers)
                result = Masking.apply(result, masking: masked)
                try await state.record(AuditEvent(
                    connection: name,
                    client: client,
                    action: readOnly ? .read : .write,
                    sql: statement.text,
                    rows: result.rowsAffected ?? result.rows.count,
                    elapsedMilliseconds: result.elapsedMilliseconds
                ))
                return .result(AgentResult(
                    connection: name,
                    result: result,
                    maskedColumns: masked.sorted().map { result.columns[$0].name },
                    readOnly: readOnly
                ))
            } catch {
                await session.close()
                try? await state.record(AuditEvent(
                    connection: name, client: client, action: .failed, sql: statement.text, detail: "\(error)"
                ))
                throw error
            }
        }
    }

    /// An agent asks for a change explicitly, with a reason a person will read.
    public func propose(connection name: String, sql: String, reason: String?, client: String) async throws -> AgentOutcome {
        let profile = try visibleProfile(named: name)
        switch AgentPolicy.evaluateProposal(sql, on: profile) {
        case .deny(let message):
            try await state.record(AuditEvent(connection: name, client: client, action: .denied, sql: sql, detail: message))
            return .denied(message)
        case .propose(let statement):
            return .proposed(try await file(statement.text, reason: reason, on: profile, client: client))
        case .run:
            return .denied("Nothing to propose.")
        }
    }

    public func tables(connection name: String) async throws -> [TableSummary] {
        let profile = try visibleProfile(named: name)
        let session = try await agentSession(profile)
        defer { Task { await session.close() } }
        return try await session.tables().filter { !AgentPolicy.isHidden(table: $0.name, rules: profile.rules) }
    }

    public func describe(connection name: String, table: String) async throws -> TableDescription {
        let profile = try visibleProfile(named: name)
        guard !AgentPolicy.isHidden(table: table, rules: profile.rules) else { throw DatabaseError.tableNotFound(table) }
        let session = try await agentSession(profile)
        defer { Task { await session.close() } }
        return try await session.describe(table: table)
    }

    /// Tables and columns whose names contain `text`, so agents can find their way without
    /// loading the whole schema into context.
    public func searchSchema(connection name: String, text: String) async throws -> [SchemaMatch] {
        let profile = try visibleProfile(named: name)
        let needle = text.lowercased()
        let session = try await agentSession(profile)
        defer { Task { await session.close() } }
        var matches: [SchemaMatch] = []
        for table in try await session.tables() where !AgentPolicy.isHidden(table: table.name, rules: profile.rules) {
            if table.name.lowercased().contains(needle) {
                matches.append(SchemaMatch(table: table.name))
            }
            for column in try await session.describe(table: table.name).columns where column.name.lowercased().contains(needle) {
                matches.append(SchemaMatch(table: table.name, column: column.name, type: column.type))
            }
        }
        return matches
    }

    // MARK: - Saved queries

    /// The person's saved queries on this connection, so an agent can pick one to improve.
    public var queries: QueryLibrary { QueryLibrary(profiles: profiles) }

    public func savedQueries(connection name: String, client: String) async throws -> [SavedQueryFile] {
        let profile = try visibleProfile(named: name)
        let files = queries.list(connection: profile.name)
        try await state.record(AuditEvent(connection: name, client: client, action: .opened, sql: "", detail: "saved queries"))
        return files
    }

    /// One saved query's text. Queries that mention a hidden table are not shown.
    public func savedQuery(connection name: String, query: String, client: String) async throws -> String {
        let profile = try visibleProfile(named: name)
        let file = try QueryLibrary.fileName(query)
        guard let text = try queries.read(connection: profile.name, name: file) else {
            throw StoreError.notFound(file, known: queries.list(connection: profile.name).map(\.name))
        }
        let mentioned = Set(SQLAnalyzer.statements(in: text, dialect: profile.engine.sqlDialect).flatMap(\.identifiers))
        if mentioned.contains(where: { AgentPolicy.isHidden(table: $0, rules: profile.rules) }) {
            let reason = "\(file) mentions a table hidden from agents."
            try await state.record(AuditEvent(connection: name, client: client, action: .denied, sql: "", detail: reason))
            throw DatabaseError.unsupported(reason)
        }
        try await state.record(AuditEvent(connection: name, client: client, action: .opened, sql: "", detail: file))
        return text
    }

    /// Files new text for a saved query (or a new one) for the person to accept or dismiss in
    /// the SQL tab. Nothing runs: accepting only puts the text in the editor.
    public func suggest(connection name: String, query: String, sql: String, note: String?, client: String) async throws -> SQLSuggestion {
        let profile = try visibleProfile(named: name)
        let file = try QueryLibrary.fileName(query)
        let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DatabaseError.unsupported("The suggestion is empty.") }
        guard text.utf8.count <= SQLSuggestion.maxSQL else { throw DatabaseError.unsupported("The suggestion is longer than 100 KB.") }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestion = SQLSuggestion(
            connection: profile.name,
            client: client,
            query: file,
            base: try queries.read(connection: profile.name, name: file) ?? "",
            sql: text + "\n",
            note: trimmedNote.flatMap { $0.isEmpty ? nil : String($0.prefix(SQLSuggestion.maxNote)) }
        )
        try await state.add(suggestion)
        try await state.record(AuditEvent(connection: name, client: client, action: .suggested, sql: suggestion.sql, detail: file))
        return suggestion
    }

    // MARK: - Helpers

    /// Agents read as their own role when one is set; otherwise as the connection's user.
    private func agentSession(_ profile: ConnectionProfile) async throws -> any DatabaseSession {
        var target = profile
        var password = try secrets.password(for: profile.id)
        if let user = profile.agentUser, let credential = profile.agentCredentialID {
            target.user = user
            password = try secrets.password(for: credential)
        }
        return try await sessions.open(target, password: password, readOnly: true)
    }

    private func visibleProfile(named name: String) throws -> ConnectionProfile {
        let profile = try profiles.profile(named: name)
        guard profile.effectiveAgentAccess != .off else {
            throw StoreError.notFound(name, known: try connections().map(\.name))
        }
        return profile
    }

    /// Stores a proposal after a trial run that is always rolled back.
    private func file(_ sql: String, reason: String?, on profile: ConnectionProfile, client: String) async throws -> Proposal {
        let session = try await sessions.open(profile, password: try secrets.password(for: profile.id), readOnly: false)
        let trial: TrialRun
        do {
            trial = try await session.trialRun(sql, timeout: .seconds(profile.limits.timeoutSeconds), maxRows: Self.previewRows)
            await session.close()
        } catch {
            await session.close()
            try? await state.record(AuditEvent(
                connection: profile.name, client: client, action: .failed, sql: sql, detail: "Trial run failed: \(error)"
            ))
            throw ProposalError.trialRunFailed("\(error)")
        }
        let proposal = Proposal(
            connection: profile.name,
            client: client,
            sql: sql,
            reason: reason,
            dryRunRows: trial.rowsChanged,
            preview: Self.preview(of: sql, trial: trial, profile: profile)
        )
        try await state.add(proposal)
        try await state.record(AuditEvent(
            connection: profile.name, client: client, action: .proposed, sql: sql, rows: trial.rowsChanged, detail: proposal.id
        ))
        return proposal
    }

    /// Rows kept from a trial run for the person to see in place.
    static let previewRows = 200

    /// The trial run's rows, masked like any agent read so the queue holds nothing agents may not see.
    static func preview(of sql: String, trial: TrialRun, profile: ConnectionProfile) -> ProposalPreview? {
        let dialect = profile.engine.sqlDialect
        guard let changed = trial.changed,
              let target = SQLAnalyzer.writeTarget(of: sql, dialect: dialect),
              let verb = SQLAnalyzer.statements(in: sql, dialect: dialect).first?.verb,
              let kind = ProposalPreview.Kind(rawValue: verb.lowercased()) else { return nil }
        let columns = changed.columns.map {
            ResultColumn(name: $0.name, typeName: $0.typeName, sourceTable: $0.sourceTable ?? target.name, sourceColumn: $0.sourceColumn ?? $0.name)
        }
        var result = changed
        result.columns = columns
        let masked = Masking.columnsToMask(columns, rules: profile.rules, mentioned: [])
        result = Masking.apply(result, masking: masked)
        return ProposalPreview(
            kind: kind,
            schema: target.schema,
            table: target.name,
            columns: changed.columns.map(\.name),
            rows: result.rows.map { $0.map { $0.isNull ? nil : $0.displayText } },
            truncated: changed.truncated
        )
    }
}

public enum ProposalError: Error, Equatable, CustomStringConvertible {
    case trialRunFailed(String)
    case notFound(String)
    case notPending(String, Proposal.Status)

    public var description: String {
        switch self {
        case .trialRunFailed(let message): "The change failed in a trial run, so it was not filed: \(message)"
        case .notFound(let id): "No proposal \(id)."
        case .notPending(let id, let status): "\(id) is already \(status.rawValue)."
        }
    }
}
