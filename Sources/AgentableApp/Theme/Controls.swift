import SwiftUI
import AgentableCore

// The design's form controls. Screens use these instead of system popup buttons, pickers and
// checkboxes, so every input looks the same everywhere.

/// A dropdown drawn as the design's select box: window color, line border, a small chevron.
struct SelectBox<Label: View, Items: View>: View {
    var height: CGFloat = 34
    var width: CGFloat? = nil
    @ViewBuilder var items: Items
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 8) {
                label
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconView(.chevronDown, size: 14)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.tmMuted)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// The design's checkbox: a rounded square, filled with its color when on.
struct CheckBox: View {
    let on: Bool
    var color: Color = .tmYou
    var size: CGFloat = 16
    var radius: CGFloat = 4

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(on ? color : Color.clear)
            RoundedRectangle(cornerRadius: radius).strokeBorder(on ? color : Color.tmLine, lineWidth: 1.5)
            if on {
                IconView(.check, size: 14)
                    .font(.system(size: size * 0.55, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A value as a small blue token, with an optional remove button.
struct Token: View {
    let text: String
    var onRemove: (() -> Void)? = nil
    /// Show the remove button only while the pointer is over the token.
    var removeOnHover = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.mono(12, .medium)).foregroundStyle(Color.tmText).lineLimit(1)
            if let onRemove, !removeOnHover || hovering {
                Button(action: onRemove) {
                    IconView(.close, size: 11, weight: 2).foregroundStyle(Color.tmMuted)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil || (removeOnHover && !hovering) ? 8 : 4)
        .frame(height: 24)
        .background(Color.tmYouTint, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// Values as tokens joined by "or", with room to type the next one. Return adds it.
struct TokenField: View {
    @Binding var values: [CellValue]
    var placeholder: LocalizedStringKey
    /// Numbers can also be separated by spaces.
    var numeric = false
    var height: CGFloat = 34
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(values.prefix(4).enumerated()), id: \.offset) { index, value in
                if index > 0 { Text("or").font(.ui(11.5)).foregroundStyle(Color.tmMuted) }
                Token(text: value.isNull ? String(localized: "empty") : value.displayText, onRemove: {
                    values.removeAll { $0 == value }
                }, removeOnHover: true)
            }
            if values.count > 4 {
                Text("+\(values.count - 4)").font(.ui(11.5)).foregroundStyle(Color.tmMuted)
            }
            TextField(values.isEmpty ? placeholder : "", text: $text)
                .textFieldStyle(.plain)
                .font(.mono(12.5))
                .focusEffectDisabled()
                .frame(minWidth: 24)
                .onSubmit(add)
        }
        .clipped()
        .padding(.leading, values.isEmpty ? 10 : 5)
        .padding(.trailing, 10)
        .frame(height: height)
        .background(Color.tmWindow, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.tmLine))
    }

    private func add() {
        let separators = CharacterSet(charactersIn: ",\n\t").union(numeric ? .whitespaces : [])
        let parts = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for part in parts where !values.contains(.text(part)) {
            values.append(.text(part))
        }
        text = ""
    }
}

/// A text-only action with an optional icon, as the design's "+ Condition" and "Ungroup".
struct TextButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    var size: CGFloat = 13
    var color: Color = .tmText2
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(size))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(hovering || configuration.isPressed ? Color.tmChip : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == TextButtonStyle {
    static var text: TextButtonStyle { TextButtonStyle() }
    static func text(height: CGFloat = 30, size: CGFloat = 13, color: Color = .tmText2) -> TextButtonStyle {
        TextButtonStyle(height: height, size: size, color: color)
    }
}

/// A plain text field in the design's input box.
struct InputField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var mono = true
    var height: CGFloat = 34
    var onSubmit: () -> Void = {}

    var body: some View {
        FieldBox(height: height) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? .mono(12.5) : .ui(13))
                .onSubmit(onSubmit)
        }
    }
}

/// The design's on/off switch: a green track when on, with a white knob.
struct ToggleSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? Color.tmOK : Color.tmLine)
                .frame(width: 36, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 18, height: 18).padding(2)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// A text field with a chevron that offers common values, as the design's Type box. Picking one
/// fills the field and commits it.
struct ComboField: View {
    /// A type name, shown as written.
    let placeholder: String
    @Binding var text: String
    let options: [String]
    var height: CGFloat = 32
    var focused = false
    var onCommit: () -> Void = {}

    var body: some View {
        FieldBox(height: height, focused: focused) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.mono(12.5))
                .onSubmit(onCommit)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) {
                        text = option
                        onCommit()
                    }
                }
            } label: {
                IconView(.chevronDown, size: 14)
                    .foregroundStyle(Color.tmMuted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
