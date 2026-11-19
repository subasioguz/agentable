import Foundation

/// The person's side of the review queue.
public struct ReviewService: Sendable {
    public let gateway: AgentGateway
    public let authenticator: any Authenticator

    public init(gateway: AgentGateway, authenticator: any Authenticator) {
        self.gateway = gateway
        self.authenticator = authenticator
    }

    public func pending() async throws -> [Proposal] {
        try await gateway.state.proposals(status: .pending)
    }

    /// Asks the person to confirm, then applies the change in its own transaction.
    public func approve(_ id: String, client: String = "you") async throws -> Proposal {
        let proposal = try await pendingProposal(id)
        try await authenticator.authenticate(reason: "apply change \(proposal.id) to \(proposal.connection)")

        let profile = try gateway.profiles.profile(named: proposal.connection)
        let session = try await gateway.sessions.open(
            profile,
            password: try gateway.secrets.password(for: profile.id),
            readOnly: false
        )
        do {
            let counts = try await session.apply([proposal.sql], timeout: .seconds(max(profile.limits.timeoutSeconds, 60)))
            await session.close()
            let rows = counts.reduce(0, +)
            let summary = "\(rows) row\(rows == 1 ? "" : "s") changed"
            try await gateway.state.decide(id, status: .applied, result: summary)
            try await gateway.state.record(AuditEvent(
                connection: proposal.connection, client: client, action: .applied, sql: proposal.sql, rows: rows, detail: id
            ))
        } catch {
            await session.close()
            try await gateway.state.decide(id, status: .failed, result: "\(error)")
            try await gateway.state.record(AuditEvent(
                connection: proposal.connection, client: client, action: .failed, sql: proposal.sql, detail: "\(id): \(error)"
            ))
            throw error
        }
        return try await gateway.state.proposal(id: id) ?? proposal
    }

    /// Runs a statement the person wrote inside a transaction that is always rolled back, to tell
    /// them what it would change before it waits for saving. Uses their own credentials.
    public func trial(connection name: String, sql: String, maxRows: Int = 0) async throws -> TrialRun {
        let profile = try gateway.profiles.profile(named: name)
        let session = try await gateway.sessions.open(
            profile,
            password: try gateway.secrets.password(for: profile.id),
            readOnly: false
        )
        do {
            let run = try await session.trialRun(sql, timeout: .seconds(max(profile.limits.timeoutSeconds, 30)), maxRows: maxRows)
            await session.close()
            return run
        } catch {
            await session.close()
            throw error
        }
    }

    /// Applies the person's staged edits and the chosen proposals together, in one transaction on
    /// one connection: all of it or none of it. Proposals widen what agents did, so when any are
    /// included the person confirms once for the whole batch.
    @discardableResult
    public func apply(connection name: String, edits: [RowChange], proposalIDs: [String], client: String = "you") async throws -> Int {
        guard !edits.isEmpty || !proposalIDs.isEmpty else { return 0 }
        let profile = try gateway.profiles.profile(named: name)
        var proposals: [Proposal] = []
        for id in proposalIDs {
            let proposal = try await pendingProposal(id)
            guard proposal.connection == profile.name else { throw ProposalError.notFound(id) }
            proposals.append(proposal)
        }
        if !proposals.isEmpty {
            let total = edits.count + proposals.count
            try await authenticator.authenticate(reason: "apply \(total) change\(total == 1 ? "" : "s") to \(profile.name)")
        }

        let dialect = profile.engine.sqlDialect
        let editStatements = try edits.map { try $0.statements(dialect: dialect) }
        // Masks follow renamed columns: the new name is masked before the rename can run, and the
        // old name's rule goes once it has.
        let carried = try carryMasks(of: edits, connection: profile.name)
        let statements = editStatements.flatMap { $0 } + proposals.map { BoundSQL($0.sql) }
        let session = try await gateway.sessions.open(
            profile,
            password: try gateway.secrets.password(for: profile.id),
            readOnly: false
        )
        let counts: [Int]
        do {
            counts = try await session.apply(statements, timeout: .seconds(max(profile.limits.timeoutSeconds, 60)))
            await session.close()
        } catch {
            await session.close()
            try? await gateway.state.record(AuditEvent(
                connection: profile.name, client: client, action: .failed,
                sql: statements.map(\.text).joined(separator: ";\n"), detail: "\(error)"
            ))
            throw error
        }

        if !carried.isEmpty, var current = try? gateway.profiles.profile(named: profile.name) {
            current.rules.maskedColumns.removeAll { carried.contains($0) }
            try? gateway.profiles.update(current)
        }

        var offset = 0
        for (edit, pieces) in zip(edits, editStatements) {
            let rows = counts[offset..<offset + pieces.count].reduce(0, +)
            offset += pieces.count
            try await gateway.state.record(AuditEvent(
                connection: profile.name, client: client, action: .write, sql: edit.displaySQL(dialect: dialect),
                rows: edit.schemaChange == nil ? rows : nil,
                detail: "\(edit.table.name) \(edit.keyLabel): \(edit.summary)"
            ))
        }
        for (proposal, rows) in zip(proposals, counts.dropFirst(offset)) {
            try await gateway.state.decide(proposal.id, status: .applied, result: "\(rows) row\(rows == 1 ? "" : "s") changed")
            try await gateway.state.record(AuditEvent(
                connection: profile.name, client: client, action: .applied, sql: proposal.sql, rows: rows, detail: proposal.id
            ))
        }
        return counts.reduce(0, +)
    }

    /// Adds mask rules for the new names of renamed masked columns (narrowing, so no
    /// confirmation) and returns the old rules, to remove after the rename is applied.
    private func carryMasks(of edits: [RowChange], connection: String) throws -> [String] {
        var profile = try gateway.profiles.profile(named: connection)
        var old: [String] = []
        for edit in edits {
            guard case .alterColumn(let before, let after)? = edit.schemaChange, before.name != after.name else { continue }
            for rule in profile.rules.maskRules(table: edit.table.name, column: before.name) {
                let renamed = VisibilityRules.renamed(rule, to: after.name)
                if !profile.rules.maskedColumns.contains(renamed) { profile.rules.maskedColumns.append(renamed) }
                old.append(rule)
            }
        }
        if !old.isEmpty { try gateway.profiles.update(profile) }
        return old
    }

    /// Rejecting needs no confirmation: it only ever narrows what happens.
    public func reject(_ id: String, note: String?, client: String = "you") async throws -> Proposal {
        let proposal = try await pendingProposal(id)
        try await gateway.state.decide(id, status: .rejected, result: note)
        try await gateway.state.record(AuditEvent(
            connection: proposal.connection, client: client, action: .rejected, sql: proposal.sql, detail: note ?? id
        ))
        return try await gateway.state.proposal(id: id) ?? proposal
    }

    private func pendingProposal(_ id: String) async throws -> Proposal {
        guard let proposal = try await gateway.state.proposal(id: id) else { throw ProposalError.notFound(id) }
        guard proposal.status == .pending else { throw ProposalError.notPending(id, proposal.status) }
        return proposal
    }
}
