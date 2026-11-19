import AppKit
import SwiftUI
import AgentableCore

/// The design's color tokens. Light is the neutral gray theme, dark the night theme. You are blue,
/// agents are orange. Every color follows the window's appearance.
extension NSColor {
    static let tmBackdrop = dynamic(0xE6E7EA, 0x0A0B0D)
    static let tmWindow = dynamic(0xFCFCFD, 0x141518)
    static let tmSide = dynamic(0xF3F4F6, 0x18191D)
    static let tmPanel = dynamic(0xF7F8FA, 0x16171A)
    static let tmLine = dynamic(0xE2E4E9, 0x2A2C31)
    static let tmLine2 = dynamic(0xEDEEF1, 0x202226)
    static let tmText = dynamic(0x16181D, 0xECEDEF)
    static let tmText2 = dynamic(0x3B3F47, 0xC9CCD1)
    static let tmMuted = dynamic(0x676C75, 0x989CA5)
    static let tmYou = dynamic(0x2F5BFF, 0x86A2FF)
    static let tmYouTint = dynamic(0xEDF2FF, 0x1A2240)
    static let tmAgent = dynamic(0xF0561D, 0xFF7A45)
    static let tmAgentTint = dynamic(0xFFF3ED, 0x271811)
    static let tmAgentText = dynamic(0xB93A0B, 0xFF9A70)
    static let tmAgentFlag = dynamic(0xC2410C, 0xFF7A45)
    static let tmAgentFlagText = dynamic(0xFFFFFF, 0x1A0B04)
    static let tmOK = dynamic(0x127A3E, 0x5AD68A)
    static let tmOKTint = dynamic(0xE7F6EC, 0x13261B)
    static let tmWarn = dynamic(0x8A5A00, 0xE3B341)
    static let tmBad = dynamic(0xB42318, 0xF58A80)
    static let tmProd = dynamic(0xC42B30, 0xFF8A8A)
    static let tmChip = dynamic(0xEEF0F3, 0x212328)
    static let tmButton = dynamic(0x16181D, 0xECEDEF)
    static let tmButtonText = dynamic(0xFFFFFF, 0x141518)
    /// SQL in the editor: keywords and functions, string literals, numbers.
    static let tmSQLKeyword = dynamic(0x2F4FD8, 0x8FA8FF)
    static let tmSQLString = dynamic(0x8F4A00, 0xE9B872)
    static let tmSQLNumber = dynamic(0x7C3AED, 0xC9A8FF)
    static let tmShadow = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.black.withAlphaComponent(0.75) : NSColor(hex: 0x101218).withAlphaComponent(0.28)
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        let lightColor = NSColor(hex: light)
        let darkColor = NSColor(hex: dark)
        return NSColor(name: nil) { $0.isDark ? darkColor : lightColor }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    static let tmBackdrop = Color(nsColor: .tmBackdrop)
    static let tmSQLKeyword = Color(nsColor: .tmSQLKeyword)
    static let tmSQLString = Color(nsColor: .tmSQLString)
    static let tmWindow = Color(nsColor: .tmWindow)
    static let tmSide = Color(nsColor: .tmSide)
    static let tmPanel = Color(nsColor: .tmPanel)
    static let tmLine = Color(nsColor: .tmLine)
    static let tmLine2 = Color(nsColor: .tmLine2)
    static let tmText = Color(nsColor: .tmText)
    static let tmText2 = Color(nsColor: .tmText2)
    static let tmMuted = Color(nsColor: .tmMuted)
    static let tmYou = Color(nsColor: .tmYou)
    static let tmYouTint = Color(nsColor: .tmYouTint)
    static let tmAgent = Color(nsColor: .tmAgent)
    static let tmAgentTint = Color(nsColor: .tmAgentTint)
    static let tmAgentText = Color(nsColor: .tmAgentText)
    static let tmAgentFlag = Color(nsColor: .tmAgentFlag)
    static let tmAgentFlagText = Color(nsColor: .tmAgentFlagText)
    static let tmOK = Color(nsColor: .tmOK)
    static let tmOKTint = Color(nsColor: .tmOKTint)
    static let tmWarn = Color(nsColor: .tmWarn)
    static let tmBad = Color(nsColor: .tmBad)
    static let tmProd = Color(nsColor: .tmProd)
    static let tmChip = Color(nsColor: .tmChip)
    static let tmButton = Color(nsColor: .tmButton)
    static let tmButtonText = Color(nsColor: .tmButtonText)
    static let tmShadow = Color(nsColor: .tmShadow)
}

extension DeploymentEnvironment {
    /// The dot next to a connection's name.
    var dotColor: Color {
        switch self {
        case .local: Color(nsColor: NSColor(hex: 0x22A35A))
        case .dev: Color(nsColor: NSColor(hex: 0x3B82F6))
        case .staging: Color(nsColor: NSColor(hex: 0xE3A008))
        case .production: Color(nsColor: NSColor(hex: 0xE5484D))
        }
    }

    /// Group headings in the connection list.
    var headingColor: Color {
        switch self {
        case .production: .tmProd
        case .staging: .tmWarn
        case .dev: .tmYou
        case .local: .tmOK
        }
    }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
