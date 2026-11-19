import AppKit
import CoreText
import SwiftUI

/// Instrument Sans for the interface, Spline Sans Mono for data and SQL. Both ship with the app
/// (SIL Open Font License, see Resources/Fonts).
enum Fonts {
    /// Registers the bundled fonts for this process. Safe to call more than once.
    static func register() {
        guard let directory = fontDirectory() else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// The fonts folder: inside the app bundle's resources, or next to the executable in a SwiftPM build.
    private static func fontDirectory() -> URL? {
        let bundleName = "Agentable_AgentableApp.bundle"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appending(path: "Fonts"))
            candidates.append(resources.appending(path: bundleName).appending(path: "Fonts"))
            candidates.append(resources.appending(path: bundleName).appending(path: "Contents/Resources/Fonts"))
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable.appending(path: bundleName).appending(path: "Fonts"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func uiName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "InstrumentSans-Bold"
        case .semibold: "InstrumentSans-SemiBold"
        case .medium: "InstrumentSans-Medium"
        default: "InstrumentSans-Regular"
        }
    }

    static func monoName(_ weight: Font.Weight) -> String {
        switch weight {
        case .semibold, .bold, .heavy, .black: "SplineSansMono-SemiBold"
        case .medium: "SplineSansMono-Medium"
        default: "SplineSansMono-Regular"
        }
    }

    static func ns(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        NSFont(name: uiName(weight), size: size) ?? .systemFont(ofSize: size, weight: weight.nsWeight)
    }

    static func nsMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        NSFont(name: monoName(weight), size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
    }
}

extension Font {
    /// Interface text.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.uiName(weight), fixedSize: size)
    }

    /// Data, identifiers and SQL.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.monoName(weight), fixedSize: size)
    }
}

extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
    }
}
