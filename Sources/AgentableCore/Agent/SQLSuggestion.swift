import Foundation

/// New text an agent suggests for one of the person's saved queries. It only ever becomes the
/// editor's text when the person accepts it; running it still goes through the usual paths.
public struct SQLSuggestion: Sendable, Codable, Hashable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case pending, accepted, dismissed
        /// A newer suggestion for the same query took its place.
        case replaced
    }

    public var id: String
    public var createdAt: Date
    public var connection: String
    public var client: String
    /// The saved query's file name, "charged-twice.sql".
    public var query: String
    /// The query's text when the suggestion was made; empty for a new query.
    public var base: String
    public var sql: String
    public var note: String?
    public var status: Status
    public var decidedAt: Date?

    public init(
        id: String = SQLSuggestion.newID(),
        createdAt: Date = .now,
        connection: String,
        client: String,
        query: String,
        base: String,
        sql: String,
        note: String?,
        status: Status = .pending,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.connection = connection
        self.client = client
        self.query = query
        self.base = base
        self.sql = sql
        self.note = note
        self.status = status
        self.decidedAt = decidedAt
    }

    public static func newID() -> String {
        "s-" + String(format: "%06x", UInt32.random(in: 0...0xFFFFFF))
    }

    /// Longest SQL and note an agent may suggest.
    public static let maxSQL = 100_000
    public static let maxNote = 600
}

/// One line of a line-by-line comparison.
public enum LineChange: Sendable, Hashable {
    case same(String)
    case added(String)
    case removed(String)

    public var text: String {
        switch self {
        case .same(let text), .added(let text), .removed(let text): text
        }
    }
}

public enum LineDiff {
    /// The lines of `old` and `new` in order, marked as kept, added or removed (longest common
    /// subsequence). Very long texts are compared as a whole replacement.
    public static func lines(from old: String, to new: String) -> [LineChange] {
        let a = Self.split(old)
        let b = Self.split(new)
        guard a.count * b.count <= 4_000_000 else {
            return a.map(LineChange.removed) + b.map(LineChange.added)
        }
        // lengths[i][j]: common lines of a[i...] and b[j...].
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var changes: [LineChange] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                changes.append(.same(a[i]))
                i += 1
                j += 1
            } else if i < a.count, j == b.count || lengths[i + 1][j] >= lengths[i][j + 1] {
                // A changed line reads as the old one removed, then the new one added.
                changes.append(.removed(a[i]))
                i += 1
            } else {
                changes.append(.added(b[j]))
                j += 1
            }
        }
        return changes
    }

    /// Lines without the empty one after a final newline.
    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
