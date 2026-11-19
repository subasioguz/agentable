import Foundation

/// A saved query: one `.sql` file.
public struct SavedQueryFile: Sendable, Hashable, Identifiable {
    public var name: String
    public var modified: Date
    public var url: URL

    public var id: URL { url }
}

/// The person's saved queries: `.sql` files in `queries/<connection>` next to connections.json.
/// The app writes them from the SQL tab; agents may read them and suggest changes, by file name.
public struct QueryLibrary: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The library next to a connections file.
    public init(profiles: ProfileStore) {
        self.init(root: profiles.file.deletingLastPathComponent().appending(path: "queries", directoryHint: .isDirectory))
    }

    public func folder(connection: String) -> URL {
        let name = connection.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    /// Newest first.
    public func list(connection: String) -> [SavedQueryFile] {
        let folder = folder(connection: connection)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "sql" }.map { url in
            SavedQueryFile(
                name: url.lastPathComponent,
                modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
                url: url
            )
        }
        .sorted { $0.modified > $1.modified }
    }

    public func url(connection: String, name: String) throws -> URL {
        folder(connection: connection).appending(path: try Self.fileName(name))
    }

    /// The query's text, or `nil` when there is no such file.
    public func read(connection: String, name: String) throws -> String? {
        let url = try url(connection: connection, name: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ text: String, connection: String, name: String) throws -> URL {
        let folder = folder(connection: connection)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appending(path: try Self.fileName(name))
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// "charged-twice" → "charged-twice.sql". A name is one plain file name: slashes and colons
    /// become dashes, and names that start with a dot are refused, so it never leaves the folder.
    public static func fileName(_ name: String) throws -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".sql") { base = String(base.dropLast(4)) }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !base.isEmpty, !base.hasPrefix("."), base.count <= 100,
              !base.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw DatabaseError.unsupported("Give the query a short name, like charged-twice.")
        }
        return base + ".sql"
    }
}
