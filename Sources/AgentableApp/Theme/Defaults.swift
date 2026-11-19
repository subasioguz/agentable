import Foundation
import AgentableCore

/// The app's preferences. Snapshot runs read nothing and write nothing, so they never touch the
/// person's own settings.
@MainActor
enum Defaults {
    /// Where a table's layout is kept: one key per connection and table.
    static func layoutKey(_ connection: UUID, _ table: TableRef) -> String {
        "layout.\(connection.uuidString).\(table.path)"
    }

    static func layout(_ key: String) -> TableLayout? {
        guard let text = string(key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TableLayout.self, from: data)
    }

    static func setLayout(_ layout: TableLayout?, _ key: String) {
        let text = layout.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        set(text, key)
    }

    private static var store: UserDefaults? { Snapshot.isActive ? nil : .standard }

    /// The app was called Tablemate before: its preferences (layouts, theme, panels) move over once.
    static func moveLegacyPreferences() {
        guard let store, !store.bool(forKey: "movedFromTablemate"),
              let old = UserDefaults(suiteName: "dev.tablemate.app")?.persistentDomain(forName: "dev.tablemate.app") else { return }
        for (key, value) in old where store.object(forKey: key) == nil { store.set(value, forKey: key) }
        store.set(true, forKey: "movedFromTablemate")
    }

    static func string(_ key: String) -> String? { store?.string(forKey: key) }
    static func bool(_ key: String) -> Bool { store?.bool(forKey: key) ?? false }
    static func dictionary(_ key: String) -> [String: Any]? { store?.dictionary(forKey: key) }
    static func set(_ value: Any?, _ key: String) { store?.set(value, forKey: key) }
}
