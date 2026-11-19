import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

/// A session on a PostgreSQL server.
///
/// Every call runs in its own transaction: `BEGIN READ ONLY` for reads, a `statement_timeout`
/// and `lock_timeout` set with `SET LOCAL`, and the extended query protocol, which refuses more
/// than one statement per call at the server. Reads go through a cursor so the row limit holds
/// without fetching the whole result.
public actor PostgresSession: DatabaseSession {
    private let connection: PostgresConnection
    private let readOnly: Bool
    private let logger: Logger
    /// Gives back the SSH tunnel, if the session runs through one.
    private let release: (@Sendable () -> Void)?
    /// One call at a time: each call is a transaction on the one connection, and the actor alone
    /// would let calls interleave at every `await`.
    private let gate = SerialGate()

    private init(connection: PostgresConnection, readOnly: Bool, logger: Logger, release: (@Sendable () -> Void)? = nil) {
        self.release = release
        self.connection = connection
        self.readOnly = readOnly
        self.logger = logger
    }

    /// Connects directly, or through an SSH tunnel when the profile has one. TLS checks the
    /// certificate against the real host name either way.
    public static func connect(profile: ConnectionProfile, password: String?, readOnly: Bool) async throws -> PostgresSession {
        guard let host = profile.host, !host.isEmpty else { throw DatabaseError.missingDatabase }
        let tls: PostgresConnection.Configuration.TLS
        switch profile.tls {
        case .disable:
            tls = .disable
        case .prefer, .require:
            let context = try NIOSSLContext(configuration: tlsConfiguration(profile.tlsFiles, verify: false))
            tls = profile.tls == .prefer ? .prefer(context) : .require(context)
        case .verifyFull:
            tls = .require(try NIOSSLContext(configuration: tlsConfiguration(profile.tlsFiles, verify: true)))
        }

        var tunnel: (port: Int, release: @Sendable () -> Void)?
        if let ssh = profile.ssh {
            tunnel = try await SSHTunnels.shared.acquire(ssh, targetHost: host, targetPort: profile.port ?? 5432)
        }
        var configuration = PostgresConnection.Configuration(
            host: tunnel == nil ? host : "127.0.0.1",
            port: tunnel?.port ?? profile.port ?? 5432,
            username: profile.user ?? NSUserName(),
            password: password,
            database: profile.database,
            tls: tls
        )
        configuration.options.connectTimeout = .seconds(10)
        if tunnel != nil { configuration.options.tlsServerName = host }
        let logger = Logger(label: "agentable.postgres") { _ in SwiftLogNoOpLogHandler() }

        do {
            let connection = try await PostgresConnection.connect(configuration: configuration, id: 1, logger: logger)
            return PostgresSession(connection: connection, readOnly: readOnly, logger: logger, release: tunnel?.release)
        } catch {
            tunnel?.release()
            throw DatabaseError.openFailed(Self.message(error))
        }
    }

    static func tlsConfiguration(_ files: TLSFiles?, verify: Bool) throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = verify ? .fullVerification : .none
        func path(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return (value as NSString).expandingTildeInPath
        }
        do {
            if let root = path(files?.rootCertificate) { configuration.trustRoots = .file(root) }
            if let certificate = path(files?.clientCertificate) {
                configuration.certificateChain = try NIOSSLCertificate.fromPEMFile(certificate).map { .certificate($0) }
            }
            if let key = path(files?.clientKey) { configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: key, format: .pem)) }
        } catch {
            throw DatabaseError.openFailed("Could not read a TLS certificate file: \(error)")
        }
        return configuration
    }

    // MARK: - DatabaseSession

    public func run(_ query: BoundSQL, options: QueryOptions) async throws -> QueryResult {
        await gate.enter()
        defer { gate.leave() }
        let binds = try Self.bindings(query.binds)
        let statements = SQLAnalyzer.statements(in: query.text, dialect: .postgres)
        guard let statement = statements.first else { throw DatabaseError.statementFailed("The query is empty.") }
        guard statements.count == 1 else { throw DatabaseError.multipleStatements(statements.count) }

        let readOnly = options.readOnly || self.readOnly
        if readOnly && statement.kind != .read { throw DatabaseError.readOnlyViolation }

        let started = ContinuousClock.now
        try await execute(readOnly ? "BEGIN READ ONLY" : "BEGIN")
        do {
            try await setLimits(options.timeout)
            var result: QueryResult
            if statement.kind == .read, ["SELECT", "WITH", "VALUES", "TABLE"].contains(statement.verb) {
                try await connection.query(
                    PostgresQuery(unsafeSQL: "DECLARE agentable_cursor NO SCROLL CURSOR FOR \(statement.text)", binds: binds),
                    logger: logger
                )
                let rows = try await connection.query(
                    PostgresQuery(unsafeSQL: "FETCH \(options.maxRows + 1) FROM agentable_cursor"),
                    logger: logger
                )
                result = try await collect(rows, maxRows: options.maxRows)
            } else if statement.kind == .read {
                let rows = try await connection.query(PostgresQuery(unsafeSQL: statement.text, binds: binds), logger: logger)
                result = try await collect(rows, maxRows: options.maxRows)
            } else {
                let outcome = try await connection.query(PostgresQuery(unsafeSQL: statement.text, binds: binds), logger: logger).get()
                result = QueryResult(
                    columns: outcome.rows.first.map { $0.map { ResultColumn(name: $0.columnName) } } ?? [],
                    rows: outcome.rows.prefix(options.maxRows).map { $0.map(Self.value) },
                    truncated: outcome.rows.count > options.maxRows,
                    rowsAffected: outcome.metadata.rows ?? 0
                )
            }
            try await execute("COMMIT")
            result.elapsed = ContinuousClock.now - started
            return result
        } catch {
            try? await execute("ROLLBACK")
            throw Self.map(error, timeout: options.timeout)
        }
    }

    public func trialRun(_ sql: String, timeout: Duration, maxRows: Int) async throws -> TrialRun {
        await gate.enter()
        defer { gate.leave() }
        guard !readOnly else { throw DatabaseError.readOnlyViolation }
        let statements = SQLAnalyzer.statements(in: sql, dialect: .postgres)
        guard statements.count == 1, let statement = statements.first else {
            throw DatabaseError.multipleStatements(statements.count)
        }
        try await execute("BEGIN")
        do {
            try await setLimits(timeout)
            var trial: TrialRun?
            if maxRows > 0, TrialRun.canReturnRows(statement) {
                try await execute("SAVEPOINT agentable_preview")
                do {
                    let outcome = try await connection.query(PostgresQuery(unsafeSQL: statement.text + " RETURNING *"), logger: logger).get()
                    let columns = outcome.rows.first.map { $0.map { ResultColumn(name: $0.columnName) } } ?? []
                    trial = TrialRun(
                        rowsChanged: outcome.metadata.rows ?? outcome.rows.count,
                        changed: QueryResult(
                            columns: columns,
                            rows: outcome.rows.prefix(maxRows).map { $0.map(Self.value) },
                            truncated: outcome.rows.count > maxRows
                        )
                    )
                } catch {
                    try await execute("ROLLBACK TO SAVEPOINT agentable_preview")
                }
            }
            if trial == nil {
                let outcome = try await connection.query(PostgresQuery(unsafeSQL: statement.text), logger: logger).get()
                trial = TrialRun(rowsChanged: outcome.metadata.rows ?? 0)
            }
            try await execute("ROLLBACK")
            return trial!
        } catch {
            try? await execute("ROLLBACK")
            throw Self.map(error, timeout: timeout)
        }
    }

    public func apply(_ statements: [BoundSQL], timeout: Duration) async throws -> [Int] {
        await gate.enter()
        defer { gate.leave() }
        guard !readOnly else { throw DatabaseError.readOnlyViolation }
        try await execute("BEGIN")
        do {
            try await setLimits(timeout)
            var counts: [Int] = []
            for item in statements {
                let pieces = SQLAnalyzer.statements(in: item.text, dialect: .postgres)
                guard pieces.count == 1, let statement = pieces.first else {
                    throw DatabaseError.multipleStatements(pieces.count)
                }
                let query = PostgresQuery(unsafeSQL: statement.text, binds: try Self.bindings(item.binds))
                let count = try await connection.query(query, logger: logger).get().metadata.rows ?? 0
                if let expected = item.expectedRows, expected != count {
                    throw DatabaseError.unexpectedRowCount(expected: expected, actual: count)
                }
                counts.append(count)
            }
            try await execute("COMMIT")
            return counts
        } catch {
            try? await execute("ROLLBACK")
            throw Self.map(error, timeout: timeout)
        }
    }

    public func tables() async throws -> [TableSummary] {
        await gate.enter()
        defer { gate.leave() }
        return try await catalog("""
            SELECT n.nspname::text, c.relname::text, c.relkind::text
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
            ORDER BY n.nspname = 'public' DESC, n.nspname, c.relname
            """).compactMap { row in
            guard let schema = Self.text(row[0]), let name = Self.text(row[1]) else { return nil }
            let kind: TableSummary.Kind = ["v", "m"].contains(Self.text(row[2]) ?? "") ? .view : .table
            return TableSummary(schema: schema, name: name, kind: kind)
        }
    }

    public func describe(table: String) async throws -> TableDescription {
        await gate.enter()
        defer { gate.leave() }
        let parts = table.split(separator: ".").map(String.init)
        let name = parts.last ?? table
        let schema = parts.count > 1 ? parts[parts.count - 2] : ""
        let found = try await catalog("""
            SELECT n.nspname::text, c.relname::text, c.relkind::text, c.oid::int8
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND lower(c.relname) = lower(\(name))
              AND (\(schema) = '' OR n.nspname = \(schema))
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY n.nspname = 'public' DESC, n.nspname
            LIMIT 1
            """)
        guard let row = found.first, let oid = Self.integer(row[3]) else { throw DatabaseError.tableNotFound(table) }
        let summary = TableSummary(
            schema: Self.text(row[0]),
            name: Self.text(row[1]) ?? name,
            kind: ["v", "m"].contains(Self.text(row[2]) ?? "") ? .view : .table
        )

        let columns = try await catalog("""
            SELECT a.attname::text, format_type(a.atttypid, a.atttypmod), (NOT a.attnotnull)::bool,
                   pg_get_expr(d.adbin, d.adrelid),
                   EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)),
                   (a.attidentity <> '')::bool
            FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = \(oid) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """).map { row in
            ColumnInfo(
                name: Self.text(row[0]) ?? "",
                type: Self.text(row[1]) ?? "",
                nullable: Self.bool(row[2]) ?? true,
                defaultValue: Self.text(row[3]),
                primaryKey: Self.bool(row[4]) ?? false,
                identity: Self.bool(row[5]) ?? false
            )
        }

        let foreignKeys = try await catalog("""
            SELECT a.attname::text, target.relname::text, fa.attname::text, tn.nspname::text
            FROM pg_constraint k
            CROSS JOIN LATERAL unnest(k.conkey, k.confkey) AS u(col, fcol)
            JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.col
            JOIN pg_class target ON target.oid = k.confrelid
            JOIN pg_namespace tn ON tn.oid = target.relnamespace
            JOIN pg_attribute fa ON fa.attrelid = k.confrelid AND fa.attnum = u.fcol
            WHERE k.conrelid = \(oid) AND k.contype = 'f'
            """).compactMap { row -> ForeignKeyInfo? in
            guard let column = Self.text(row[0]), let target = Self.text(row[1]) else { return nil }
            return ForeignKeyInfo(column: column, referencedTable: target, referencedColumn: Self.text(row[2]), referencedSchema: Self.text(row[3]))
        }

        let indexes = try await catalog("""
            SELECT ci.relname::text, i.indisunique,
                   array_to_string(ARRAY(
                       SELECT pg_get_indexdef(i.indexrelid, k, true) || CASE WHEN i.indoption[k - 1] & 1 = 1 THEN ' DESC' ELSE '' END
                       FROM generate_series(1, i.indnkeyatts) k), chr(31)),
                   EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid AND k.conrelid = i.indrelid AND k.contype IN ('p', 'u', 'x')),
                   am.amname::text, pg_relation_size(i.indexrelid)::int8, s.idx_scan::int8
            FROM pg_index i
            JOIN pg_class ci ON ci.oid = i.indexrelid
            JOIN pg_am am ON am.oid = ci.relam
            LEFT JOIN pg_stat_all_indexes s ON s.indexrelid = i.indexrelid
            WHERE i.indrelid = \(oid)
            ORDER BY i.indisprimary DESC, ci.relname
            """).compactMap { row -> IndexInfo? in
            guard let indexName = Self.text(row[0]) else { return nil }
            let columnList = (Self.text(row[2]) ?? "").split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }
            return IndexInfo(
                name: indexName, columns: columnList, unique: Self.bool(row[1]) ?? false, constraint: Self.bool(row[3]) ?? false,
                method: Self.text(row[4]), size: Self.integer(row[5]), scans: Self.integer(row[6])
            )
        }

        let checks = try await catalog("""
            SELECT k.conname::text, pg_get_constraintdef(k.oid, true),
                   array_to_string(ARRAY(SELECT a.attname FROM pg_attribute a WHERE a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey) ORDER BY a.attnum), chr(31))
            FROM pg_constraint k
            WHERE k.conrelid = \(oid) AND k.contype = 'c'
            ORDER BY k.conname
            """).compactMap { row -> CheckInfo? in
            guard let definition = Self.text(row[1]) else { return nil }
            let columnList = (Self.text(row[2]) ?? "").split(separator: "\u{1F}").map(String.init)
            return CheckInfo(name: Self.text(row[0]), definition: CheckInfo.condition(definition), columns: columnList)
        }

        let sizes = try await catalog("SELECT pg_total_relation_size(\(oid))::int8")
        var views: [String: [String]] = [:]
        for row in try await catalog("""
            SELECT DISTINCT a.attname::text, v.relname::text
            FROM pg_depend d
            JOIN pg_rewrite r ON r.oid = d.objid
            JOIN pg_class v ON v.oid = r.ev_class
            JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
            WHERE d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass
              AND d.refobjid = \(oid) AND d.refobjsubid > 0 AND v.oid <> \(oid)
            ORDER BY 2
            """) {
            guard let column = Self.text(row[0]), let view = Self.text(row[1]) else { continue }
            views[column, default: []].append(view)
        }

        return TableDescription(
            table: summary, columns: columns, foreignKeys: foreignKeys, indexes: indexes,
            checks: checks, size: sizes.first.flatMap { Self.integer($0[0]) }, views: views
        )
    }

    public func references(to table: String) async throws -> [IncomingReference] {
        let target = try await describe(table: table)
        await gate.enter()
        defer { gate.leave() }
        let schema = target.table.schema ?? "public"
        let name = target.table.name
        return try await catalog("""
            SELECT n.nspname::text, c.relname::text, a.attname::text, fa.attname::text
            FROM pg_constraint k
            JOIN pg_class c ON c.oid = k.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
            JOIN pg_attribute fa ON fa.attrelid = k.confrelid AND fa.attnum = k.confkey[1]
            WHERE k.contype = 'f' AND cardinality(k.conkey) = 1
              AND k.confrelid = (SELECT t.oid FROM pg_class t JOIN pg_namespace tn ON tn.oid = t.relnamespace
                                 WHERE t.relname = \(name) AND tn.nspname = \(schema))
            ORDER BY n.nspname, c.relname, a.attname
            """).compactMap { row -> IncomingReference? in
            guard let table = Self.text(row[1]), let column = Self.text(row[2]) else { return nil }
            return IncomingReference(schema: Self.text(row[0]), table: table, column: column, referencedColumn: Self.text(row[3]))
        }
    }

    public func close() async {
        try? await connection.close()
        release?()
    }

    // MARK: - Helpers

    /// Values go as untyped text, like literals, so the server infers each type from where it is
    /// used (`id = $1` compares as a number, `created_at >= $1` as a timestamp).
    static func bindings(_ values: [CellValue]) throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: values.count)
        for value in values {
            switch value {
            case .null: bindings.appendNull()
            case .blob(let data): try bindings.append(ByteBuffer(bytes: data))
            case .text(let text): bindings.append(UntypedText(value: text))
            case .integer(let number): bindings.append(UntypedText(value: String(number)))
            case .real(let number): bindings.append(UntypedText(value: String(number)))
            case .bool(let flag): bindings.append(UntypedText(value: flag ? "true" : "false"))
            }
        }
        return bindings
    }

    private func execute(_ sql: String) async throws {
        try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
    }

    private func setLimits(_ timeout: Duration) async throws {
        let milliseconds = max(1, Int(timeout.components.seconds * 1_000 + timeout.components.attoseconds / 1_000_000_000_000_000))
        try await execute("SET LOCAL statement_timeout = \(milliseconds)")
        try await execute("SET LOCAL lock_timeout = \(min(milliseconds, 5_000))")
        try await execute("SET LOCAL idle_in_transaction_session_timeout = \(milliseconds + 5_000)")
    }

    /// Catalog queries for schema views, read-only.
    private func catalog(_ query: PostgresQuery) async throws -> [[CellValue]] {
        do {
            var rows: [[CellValue]] = []
            for try await row in try await connection.query(query, logger: logger) {
                rows.append(row.map(Self.value))
            }
            return rows
        } catch {
            throw Self.map(error, timeout: .seconds(30))
        }
    }

    /// Reads the cursor batch and resolves which table column each result column came from.
    private func collect(_ sequence: PostgresRowSequence, maxRows: Int) async throws -> QueryResult {
        let columns = Array(sequence.columns)
        var rows: [[CellValue]] = []
        for try await row in sequence {
            rows.append(row.map(Self.value))
        }
        let truncated = rows.count > maxRows
        if truncated { rows = Array(rows.prefix(maxRows)) }

        var sources: [String: (table: String, column: String)] = [:]
        let tableOIDs = Set(columns.map(\.tableOID).filter { $0 != 0 })
        if !tableOIDs.isEmpty {
            let list = tableOIDs.map(String.init).joined(separator: ", ")
            let catalogRows = try await catalog(PostgresQuery(unsafeSQL: """
                SELECT a.attrelid::int8, a.attnum::int8, c.relname::text, a.attname::text
                FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                WHERE a.attrelid IN (\(list)) AND a.attnum > 0
                """))
            for row in catalogRows {
                guard let oid = Self.integer(row[0]), let attnum = Self.integer(row[1]),
                      let table = Self.text(row[2]), let column = Self.text(row[3]) else { continue }
                sources["\(oid):\(attnum)"] = (table, column)
            }
        }

        let resultColumns = columns.map { column in
            let source = sources["\(column.tableOID):\(column.columnAttributeNumber)"]
            return ResultColumn(
                name: column.name,
                typeName: "\(column.dataType)",
                sourceTable: source?.table,
                sourceColumn: source?.column
            )
        }
        return QueryResult(columns: resultColumns, rows: rows, truncated: truncated)
    }

    static func value(_ cell: PostgresCell) -> CellValue {
        guard var buffer = cell.bytes else { return .null }
        switch cell.dataType {
        case .bool:
            if let flag = try? cell.decode(Bool.self) { return .bool(flag) }
        case .int2, .int4, .int8, .oid:
            if let number = try? cell.decode(Int64.self) { return .integer(number) }
        case .float4, .float8:
            if let number = try? cell.decode(Double.self) { return .real(number) }
        case .numeric:
            if let number = try? cell.decode(Decimal.self) { return .text("\(number)") }
        case .uuid:
            if let uuid = try? cell.decode(UUID.self) { return .text(uuid.uuidString.lowercased()) }
        case .date:
            if let date = try? cell.decode(Date.self) {
                return .text(date.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)))
            }
        case .timestamp, .timestamptz:
            if let date = try? cell.decode(Date.self) { return .text(date.ISO8601Format()) }
        case .bytea:
            return .blob(Data(buffer.readableBytesView))
        case .jsonb:
            if cell.format == .binary, buffer.readableBytes > 0 { buffer.moveReaderIndex(forwardBy: 1) }
            return .text(String(buffer: buffer))
        case .json:
            return .text(String(buffer: buffer))
        default:
            break
        }
        if let text = try? cell.decode(String.self) { return .text(text) }
        if cell.format == .text { return .text(String(buffer: buffer)) }
        return .text("(\(cell.dataType))")
    }

    static func map(_ error: any Error, timeout: Duration) -> any Error {
        if error is DatabaseError { return error }
        if let psql = error as? PSQLError {
            switch psql.serverInfo?[.sqlState] {
            case "57014":
                return DatabaseError.timedOut(Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
            case "25006":
                return DatabaseError.readOnlyViolation
            default:
                break
            }
        }
        return DatabaseError.statementFailed(message(error))
    }

    static func message(_ error: any Error) -> String {
        if let psql = error as? PSQLError {
            if let message = psql.serverInfo?[.message] {
                let detail = psql.serverInfo?[.detail].map { " (\($0))" } ?? ""
                return message + detail
            }
            return "\(psql.code)"
        }
        return "\(error)"
    }

    private static func text(_ value: CellValue) -> String? {
        if case .text(let text) = value { return text }
        return nil
    }

    private static func integer(_ value: CellValue) -> Int64? {
        if case .integer(let number) = value { return number }
        return nil
    }

    private static func bool(_ value: CellValue) -> Bool? {
        if case .bool(let flag) = value { return flag }
        return nil
    }
}

/// A text value whose type the server infers, as it does for a quoted literal.
struct UntypedText: PostgresNonThrowingEncodable {
    let value: String

    static var psqlType: PostgresDataType { PostgresDataType(0) }
    static var psqlFormat: PostgresFormat { .text }

    func encode<JSONEncoder: PostgresJSONEncoder>(into byteBuffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>) {
        byteBuffer.writeString(value)
    }
}

/// A first-in, first-out lock for actor methods that await.
final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiting.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func leave() {
        lock.lock()
        if waiting.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiting.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
