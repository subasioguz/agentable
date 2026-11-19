import SwiftUI

/// Bordered button on the window color: the everyday action.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13))
            .foregroundStyle(Color.tmText)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(configuration.isPressed ? Color.tmChip : Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Solid near-black button: the one action a screen is for.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13, .semibold))
            .foregroundStyle(Color.tmButtonText)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Color.tmButton.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Borderless icon or text button that shows its shape on hover.
struct QuietButtonStyle: ButtonStyle {
    var size: CGFloat? = 30
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.tmMuted)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering || configuration.isPressed ? Color.tmChip : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(height: CGFloat) -> SecondaryButtonStyle { SecondaryButtonStyle(height: height) }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(height: CGFloat) -> PrimaryButtonStyle { PrimaryButtonStyle(height: height) }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// A segmented control in the design's style: a tinted track with a raised selected segment.
struct SegmentedSwitch<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 24
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.ui(12.5, selected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.tmText : Color.tmText2)
                        // Equal-width segments center their text; a small inset leaves room for
                        // longer words in other languages.
                        .padding(.horizontal, fill ? 4 : 10)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: height)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.tmWindow)
                                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.tmChip, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A key cap, as in "⌘S".
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.mono(11, .medium))
            .foregroundStyle(Color.tmMuted)
            .padding(.horizontal, 5)
            .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.tmLine)
                    .padding(.bottom, -1)
            )
    }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String

    init(text: String.LocalizationValue) { self.text = L10n.upper(String(localized: text)) }

    /// A name from the database, upper-cased as written rather than by the language's rules.
    init(verbatim: String) { self.text = verbatim.uppercased() }

    var body: some View {
        Text(text)
            .font(.ui(11, .semibold))
            .tracking(0.66)
            .foregroundStyle(Color.tmMuted)
    }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// You (blue, filled) or an agent (orange ring; gray when idle).
struct Avatar: View {
    enum Kind { case you, agent, idleAgent }
    let kind: Kind
    var size: CGFloat = 24
    var ring: Color? = nil

    var body: some View {
        ZStack {
            Circle().fill(fill)
            IconView(kind == .you ? .you : .agent, size: size * 0.56, weight: kind == .you ? 2 : 1.9)
                .foregroundStyle(foreground)
        }
        .frame(width: size, height: size)
        .overlay {
            if kind == .agent {
                Circle().strokeBorder(Color.tmAgent, lineWidth: size > 26 ? 2 : 1.5)
            }
        }
        .overlay {
            if let ring { Circle().strokeBorder(ring, lineWidth: 2).padding(-2) }
        }
    }

    private var fill: Color {
        switch kind {
        case .you: .tmYou
        case .agent: .tmAgentTint
        case .idleAgent: .tmChip
        }
    }

    private var foreground: Color {
        switch kind {
        case .you: .white
        case .agent: .tmAgentText
        case .idleAgent: .tmMuted
        }
    }
}

/// A text field drawn like the design's inputs.
struct FieldBox<Content: View>: View {
    var height: CGFloat = 34
    var focused = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .focusEffectDisabled()
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.tmYou : Color.tmLine))
    }
}

/// Thin separator in the line color.
struct Hairline: View {
    var vertical = false
    var color: Color = .tmLine

    var body: some View {
        Rectangle().fill(color).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

extension View {
    /// The floating-card look: window color, line border, soft shadow. The shadow belongs to the
    /// card's shape only; put on the whole view it would fall under every field and button inside.
    func card(radius: CGFloat = 12, shadow: CGFloat = 0.55) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.tmWindow)
                .shadow(color: Color.tmShadow.opacity(shadow), radius: 18, y: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.tmLine))
    }
}

extension Int {
    /// 1,248,330 (1.248.330 in Turkish)
    var grouped: String { formatted(.number.grouping(.automatic).locale(L10n.locale)) }

    /// 48.2k, 1.2M (48,2 B in Turkish, 4.8万 in Japanese)
    var compact: String {
        L10n.compact(self) {
            let value = Double(self)
            switch abs(value) {
            case 1_000_000...: return trim(value / 1_000_000) + "M"
            case 1_000...: return trim(value / 1_000) + "k"
            default: return String(self)
            }
        }
    }

    private func trim(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }
}

/// Lays children out left to right and wraps to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews, width: width)
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        let used = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = lines[lines.count - 1].items.isEmpty ? size.width : lines[lines.count - 1].width + spacing + size.width
            if needed > width, !lines[lines.count - 1].items.isEmpty {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append(index)
            lines[lines.count - 1] = line
        }
        return lines
    }
}
