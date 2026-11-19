import Foundation
import SQLite3

/// Something that happened on a connection: an agent read, a denied request, an applied change.
public struct AuditEvent: Sendable, Codable, Hashable {
    public enum Action: String, Sendable, Codable {
        case read, write, proposed, denied, applied, rejected, failed
        /// An agent read one of the person's saved queries (`detail` names it).
        case opened
        /// An agent suggested new text for a saved query; the person accepted or dismissed it.
        case suggested, accepted, dismissed
        /// The person asked an agent about a saved query from the SQL tab (`detail`: agent and request).
        case asked
    }

    public var at: Date
    public var connection: String
    public var client: String
    public var action: Action
    public var sql: String
    public var rows: Int?
    public var elapsedMilliseconds: Double?
    public var detail: String?

    public init(
        at: Date = .now,
        connection: String,
        client: String,
        action: Action,
        sql: String,
        rows: Int? = nil,
        elapsedMilliseconds: Double? = nil,
        detail: String? = nil
    ) {
        self.at = at
        self.connection = connection
        self.client = client
        self.action = action
        self.sql = sql
        self.rows = rows
        self.elapsedMilliseconds = elapsedMilliseconds
        self.detail = detail
    }
}

/// The rows a proposal changed in its trial run, as text, so the app can show them in place.
public struct ProposalPreview: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case update, delete, insert }

    public var kind: Kind
    public var schema: String?
    public var table: String
    public var columns: [String]
    /// Display text per column; `nil` is NULL.
    public var rows: [[String?]]
    /// More rows changed than were kept.
    public var truncated: Bool

    public init(kind: Kind, schema: String?, table: String, columns: [String], rows: [[String?]], truncated: Bool) {
        self.kind = kind
        self.schema = schema
        self.table = table
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
    }
}

/// A change an agent asked for, waiting for a person.
public struct Proposal: Sendable, Codable, Hashable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case pending, applied, rejected, failed
    }

    public var id: String
    public var createdAt: Date
    public var connection: String
    public var client: String
    public var sql: String
    public var reason: String?
    public var status: Status
    /// Rows the statement changed in a rolled-back trial run.
    public var dryRunRows: Int?
    public var decidedAt: Date?
    public var result: String?
    /// For the app only: left out of JSON so agent output stays compact.
    public var preview: ProposalPreview? = nil

    enum CodingKeys: String, CodingKey {
        case id, createdAt, connection, client, sql, reason, status, dryRunRows, decidedAt, result
    }

    public init(
        id: String = Proposal.newID(),
        createdAt: Date = .now,
        connection: String,
        client: String,
        sql: String,
        reason: String?,
        status: Status = .pending,
        dryRunRows: Int? = nil,
        decidedAt: Date? = nil,
        result: String? = nil,
        preview: ProposalPreview? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.connection = connection
        self.client = client
        self.sql = sql
        self.reason = reason
        self.status = status
        self.dryRunRows = dryRunRows
        self.decidedAt = decidedAt
        self.result = result
        self.preview = preview
    }

    public static func newID() -> String {
        "p-" + String(format: "%06x", UInt32.random(in: 0...0xFFFFFF))
    }
}

/// An audit event with its position in the log, for following the log as it grows.
public struct LoggedEvent: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var event: AuditEvent
}

/// Agentable's own state: the audit log and the review queue, in one SQLite file.
public actor StateStore {
    private let handle: SQLiteHandle

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let handle = try SQLiteHandle(path: url.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try handle.exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY,
                at REAL NOT NULL,
                connection TEXT NOT NULL,
                client TEXT NOT NULL,
                action TEXT NOT NULL,
                sql TEXT NOT NULL,
                rows INTEGER,
                elapsed_ms REAL,
                detail TEXT
            );
            CREATE INDEX IF NOT EXISTS events_connection_at ON events (connection, at);
            CREATE TABLE IF NOT EXISTS proposals (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                connection TEXT NOT NULL,
                client TEXT NOT NULL,
                sql TEXT NOT NULL,
                reason TEXT,
                status TEXT NOT NULL,
                dry_run_rows INTEGER,
                decided_at REAL,
                result TEXT
            );
            """)
        let proposalColumns = try handle.query("PRAGMA table_info(proposals)").compactMap { row -> String? in
            if case .text(let name) = row[1] { return name }
            return nil
        }
        if !proposalColumns.contains("preview") {
            try handle.exec("ALTER TABLE proposals ADD COLUMN preview TEXT")
        }
        try handle.exec("""
            CREATE TABLE IF NOT EXISTS suggestions (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                connection TEXT NOT NULL,
                client TEXT NOT NULL,
                query TEXT NOT NULL,
                base TEXT NOT NULL,
                sql TEXT NOT NULL,
                note TEXT,
                status TEXT NOT NULL,
                decided_at REAL
            );
            """)
        self.handle = handle
    }

    // MARK: Audit

    public func record(_ event: AuditEvent) throws {
        try handle.query(
            "INSERT INTO events (at, connection, client, action, sql, rows, elapsed_ms, detail) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .real(event.at.timeIntervalSince1970),
                .text(event.connection),
                .text(event.client),
                .text(event.action.rawValue),
                .text(event.sql),
                event.rows.map { .integer(Int64($0)) } ?? .null,
                event.elapsedMilliseconds.map { .real($0) } ?? .null,
                event.detail.map { .text($0) } ?? .null,
            ]
        )
    }

    /// Newest first.
    public func events(connection: String? = nil, limit: Int = 50) throws -> [AuditEvent] {
        let rows: [[CellValue]]
        let columns = "at, connection, client, action, sql, rows, elapsed_ms, detail"
        if let connection {
            rows = try handle.query(
                "SELECT \(columns) FROM events WHERE connection = ? ORDER BY id DESC LIMIT ?",
                [.text(connection), .integer(Int64(limit))]
            )
        } else {
            rows = try handle.query("SELECT \(columns) FROM events ORDER BY id DESC LIMIT ?", [.integer(Int64(limit))])
        }
        return rows.compactMap { row in
            guard let action = AuditEvent.Action(rawValue: text(row[3]) ?? "") else { return nil }
            return AuditEvent(
                at: Date(timeIntervalSince1970: real(row[0]) ?? 0),
                connection: text(row[1]) ?? "",
                client: text(row[2]) ?? "",
                action: action,
                sql: text(row[4]) ?? "",
                rows: integer(row[5]).map(Int.init),
                elapsedMilliseconds: real(row[6]),
                detail: text(row[7])
            )
        }
    }

    /// Events after `id` (or the latest `limit` when `id` is nil), oldest first.
    public func loggedEvents(connection: String? = nil, after id: Int64? = nil, limit: Int = 200) throws -> [LoggedEvent] {
        let columns = "id, at, connection, client, action, sql, rows, elapsed_ms, detail"
        var clauses: [String] = []
        var binds: [CellValue] = []
        if let connection {
            clauses.append("connection = ?")
            binds.append(.text(connection))
        }
        if let id {
            clauses.append("id > ?")
            binds.append(.integer(id))
        }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let inner = id == nil
            ? "SELECT \(columns) FROM events \(filter) ORDER BY id DESC LIMIT ?"
            : "SELECT \(columns) FROM events \(filter) ORDER BY id ASC LIMIT ?"
        binds.append(.integer(Int64(limit)))
        let rows = try handle.query("SELECT * FROM (\(inner)) ORDER BY id ASC", binds)
        return rows.compactMap { row in
            guard let id = integer(row[0]), let action = AuditEvent.Action(rawValue: text(row[4]) ?? "") else { return nil }
            return LoggedEvent(id: id, event: AuditEvent(
                at: Date(timeIntervalSince1970: real(row[1]) ?? 0),
                connection: text(row[2]) ?? "",
                client: text(row[3]) ?? "",
                action: action,
                sql: text(row[5]) ?? "",
                rows: integer(row[6]).map(Int.init),
                elapsedMilliseconds: real(row[7]),
                detail: text(row[8])
            ))
        }
    }

    // MARK: Proposals

    public func add(_ proposal: Proposal) throws {
        try handle.query(
            """
            INSERT INTO proposals (id, created_at, connection, client, sql, reason, status, dry_run_rows, decided_at, result, preview)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(proposal.id),
                .real(proposal.createdAt.timeIntervalSince1970),
                .text(proposal.connection),
                .text(proposal.client),
                .text(proposal.sql),
                proposal.reason.map { .text($0) } ?? .null,
                .text(proposal.status.rawValue),
                proposal.dryRunRows.map { .integer(Int64($0)) } ?? .null,
                proposal.decidedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                proposal.result.map { .text($0) } ?? .null,
                try proposal.preview.map { .text(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) } ?? .null,
            ]
        )
    }

    /// Oldest first.
    public func proposals(status: Proposal.Status? = nil) throws -> [Proposal] {
        let columns = "id, created_at, connection, client, sql, reason, status, dry_run_rows, decided_at, result, preview"
        let rows: [[CellValue]]
        if let status {
            rows = try handle.query(
                "SELECT \(columns) FROM proposals WHERE status = ? ORDER BY created_at",
                [.text(status.rawValue)]
            )
        } else {
            rows = try handle.query("SELECT \(columns) FROM proposals ORDER BY created_at")
        }
        return rows.compactMap(proposal(from:))
    }

    public func proposal(id: String) throws -> Proposal? {
        let columns = "id, created_at, connection, client, sql, reason, status, dry_run_rows, decided_at, result, preview"
        return try handle.query("SELECT \(columns) FROM proposals WHERE id = ?", [.text(id)]).first.flatMap(proposal(from:))
    }

    public func decide(_ id: String, status: Proposal.Status, result: String?) throws {
        try handle.query(
            "UPDATE proposals SET status = ?, decided_at = ?, result = ? WHERE id = ?",
            [.text(status.rawValue), .real(Date.now.timeIntervalSince1970), result.map { .text($0) } ?? .null, .text(id)]
        )
    }

    // MARK: Suggestions

    /// Stores a suggestion; an earlier one still waiting for the same query is replaced.
    public func add(_ suggestion: SQLSuggestion) throws {
        try handle.query(
            "UPDATE suggestions SET status = ?, decided_at = ? WHERE connection = ? AND query = ? AND status = ?",
            [.text(SQLSuggestion.Status.replaced.rawValue), .real(suggestion.createdAt.timeIntervalSince1970),
             .text(suggestion.connection), .text(suggestion.query), .text(SQLSuggestion.Status.pending.rawValue)]
        )
        try handle.query(
            """
            INSERT INTO suggestions (id, created_at, connection, client, query, base, sql, note, status, decided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(suggestion.id),
                .real(suggestion.createdAt.timeIntervalSince1970),
                .text(suggestion.connection),
                .text(suggestion.client),
                .text(suggestion.query),
                .text(suggestion.base),
                .text(suggestion.sql),
                suggestion.note.map { .text($0) } ?? .null,
                .text(suggestion.status.rawValue),
                suggestion.decidedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            ]
        )
    }

    /// Oldest first.
    public func suggestions(status: SQLSuggestion.Status? = nil) throws -> [SQLSuggestion] {
        let columns = "id, created_at, connection, client, query, base, sql, note, status, decided_at"
        let rows = try status.map {
            try handle.query("SELECT \(columns) FROM suggestions WHERE status = ? ORDER BY created_at", [.text($0.rawValue)])
        } ?? handle.query("SELECT \(columns) FROM suggestions ORDER BY created_at")
        return rows.compactMap { row in
            guard let id = text(row[0]), let status = SQLSuggestion.Status(rawValue: text(row[8]) ?? "") else { return nil }
            return SQLSuggestion(
                id: id,
                createdAt: Date(timeIntervalSince1970: real(row[1]) ?? 0),
                connection: text(row[2]) ?? "",
                client: text(row[3]) ?? "",
                query: text(row[4]) ?? "",
                base: text(row[5]) ?? "",
                sql: text(row[6]) ?? "",
                note: text(row[7]),
                status: status,
                decidedAt: real(row[9]).map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    /// Settles a waiting suggestion; returns false when it was no longer waiting.
    @discardableResult
    public func decide(suggestion id: String, status: SQLSuggestion.Status) throws -> Bool {
        let waiting = try handle.query("SELECT 1 FROM suggestions WHERE id = ? AND status = ?", [.text(id), .text(SQLSuggestion.Status.pending.rawValue)])
        guard !waiting.isEmpty else { return false }
        try handle.query(
            "UPDATE suggestions SET status = ?, decided_at = ? WHERE id = ?",
            [.text(status.rawValue), .real(Date.now.timeIntervalSince1970), .text(id)]
        )
        return true
    }

    private func proposal(from row: [CellValue]) -> Proposal? {
        guard let id = text(row[0]), let status = Proposal.Status(rawValue: text(row[6]) ?? "") else { return nil }
        return Proposal(
            id: id,
            createdAt: Date(timeIntervalSince1970: real(row[1]) ?? 0),
            connection: text(row[2]) ?? "",
            client: text(row[3]) ?? "",
            sql: text(row[4]) ?? "",
            reason: text(row[5]),
            status: status,
            dryRunRows: integer(row[7]).map(Int.init),
            decidedAt: real(row[8]).map(Date.init(timeIntervalSince1970:)),
            result: text(row[9]),
            preview: text(row[10]).flatMap { try? JSONDecoder().decode(ProposalPreview.self, from: Data($0.utf8)) }
        )
    }

    private func text(_ value: CellValue) -> String? {
        if case .text(let text) = value { return text }
        return nil
    }

    private func integer(_ value: CellValue) -> Int64? {
        if case .integer(let number) = value { return number }
        return nil
    }

    private func real(_ value: CellValue) -> Double? {
        switch value {
        case .real(let number): number
        case .integer(let number): Double(number)
        default: nil
        }
    }
}
