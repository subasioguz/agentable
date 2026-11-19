import AppKit
import AgentableCore

/// The interface language: the Mac's, or one picked here. macOS reads it at launch, so a change
/// asks to restart. Agents' side (CLI, MCP) stays English either way. Raw values are the
/// `.lproj` folder names; adding a language also needs its folder and an entry in
/// `CFBundleLocalizations` (scripts/bundle-app.sh).
enum AppLanguage: String, CaseIterable {
    case system
    case english = "en", german = "de", spanish = "es", french = "fr", italian = "it"
    case portuguese = "pt-BR", russian = "ru", turkish = "tr", japanese = "ja", korean = "ko"
    case simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"

    /// The language's name in itself, as the menu shows it.
    var name: String {
        switch self {
        case .system: ""
        case .english: "English"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        case .portuguese: "Português (Brasil)"
        case .russian: "Русский"
        case .turkish: "Türkçe"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }

    /// Numbers and times are written as in this region.
    var localeIdentifier: String {
        switch self {
        case .system, .english: "en_US"
        case .german: "de_DE"
        case .spanish: "es_ES"
        case .french: "fr_FR"
        case .italian: "it_IT"
        case .portuguese: "pt_BR"
        case .russian: "ru_RU"
        case .turkish: "tr_TR"
        case .japanese: "ja_JP"
        case .korean: "ko_KR"
        case .simplifiedChinese: "zh_Hans_CN"
        case .traditionalChinese: "zh_Hant_TW"
        }
    }

    static var current: AppLanguage {
        guard let chosen = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = chosen.first else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    @MainActor static func choose(_ language: AppLanguage) {
        guard language != current else { return }
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Agentable to change the language?")
        alert.informativeText = String(localized: "Your connections and waiting changes are kept.")
        alert.addButton(withTitle: String(localized: "Restart"))
        alert.addButton(withTitle: String(localized: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Text the app builds itself, in the interface language. English is the development language and
/// the key; translations live in `Localization/<language>.lproj/Localizable.strings`.
///
/// SwiftUI looks up `Text("literal")`, `Button("literal")`, `.help("literal")` and the like by
/// itself, interpolations included ("Back to %@"). Everything else goes through
/// `String(localized:)`: computed labels, AppKit menus, tooltips and alerts.
enum L10n {
    /// The language text is shown in: an `AppLanguage` raw value such as "en", "tr", "zh-Hans".
    static let language = Bundle.main.preferredLocalizations.first ?? "en"

    static var isEnglish: Bool { language.hasPrefix("en") }
    static var isTurkish: Bool { language == "tr" }

    /// Numbers, times and upper case follow the interface language rather than the Mac's region,
    /// so a screen never mixes the two: 1,248,330 in English, 1.248.330 in Turkish.
    static let locale = Locale(identifier: (AppLanguage(rawValue: language) ?? .english).localeIdentifier)

    /// English text from AgentableCore in the interface language. Core is shared with the CLI and
    /// the MCP server, which stay English, so its labels are translated here with the English
    /// text as the key. Unknown text comes back unchanged.
    static func core(_ english: String) -> String {
        english.isEmpty ? english : Bundle.main.localizedString(forKey: english, value: english, table: nil)
    }

    /// Upper case by the interface language's rules: Turkish "i" becomes "İ".
    static func upper(_ text: String) -> String { text.uppercased(with: locale) }

    /// "48.2k", "1.2M" in English; the language's own short form elsewhere: "48,2 B", "4.8万".
    static func compact(_ value: Int, english: () -> String) -> String {
        isEnglish ? english() : value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }

    /// "9:41 AM", "09:41".
    static func time(_ date: Date) -> String {
        isTurkish
            ? date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
            : date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }
}

extension AgentAccess {
    /// The level's name on screen: "read", "propose". Agents and the CLI use `rawValue`.
    var label: String {
        switch self {
        case .off: String(localized: "access.off", defaultValue: "off")
        case .read: String(localized: "access.read", defaultValue: "read")
        case .propose: String(localized: "access.propose", defaultValue: "propose")
        case .write: String(localized: "access.write", defaultValue: "write")
        }
    }
}
