import AppKit
import SwiftUI
import AgentableCore

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.screen {
            case .welcome:
                WelcomeView()
            case .connections:
                ConnectionsView()
            case .workspace:
                if let workspace = app.workspace {
                    WorkspaceView(workspace: workspace)
                } else {
                    ConnectionsView()
                }
            }
        }
        .font(.ui(13))
        .foregroundStyle(Color.tmText)
        .background(Color.tmWindow)
        .ignoresSafeArea()
        .background(WindowAccessor { WindowChrome.configure($0) })
        .onChange(of: app.feed.revision) { app.workspace?.feedChanged() }
        .overlay {
            if app.showAgents {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { app.showAgents = false }
                    AgentsSheet()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .card(radius: 16, shadow: 0.6)
                }
                .onExitCommand { app.showAgents = false }
            }
        }
        .task { Snapshot.runIfRequested(app) }
    }
}

/// The window's top bar: room for the traffic lights, then the screen's own content.
struct HeaderBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) {
            content
        }
        .padding(.leading, WindowChrome.trafficLightsWidth)
        .padding(.trailing, 14)
        .frame(height: WindowChrome.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tmSide)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// The 52-point icon rail on the left edge.
struct IconRail<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 4) {
            content
        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.tmSide)
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
    }
}

struct RailButton: View {
    let icon: Icon
    let label: String
    var selected = false
    var badge: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    init(icon: Icon, label: String.LocalizationValue, selected: Bool = false, badge: Color? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.label = String(localized: label)
        self.selected = selected
        self.badge = badge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 16)
                .foregroundStyle(selected ? Color.tmText : Color.tmMuted)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(selected ? Color.tmWindow : (hovering ? Color.tmChip : .clear))
                )
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.tmLine) }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Circle().fill(badge).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color.tmSide, lineWidth: 2).padding(-2))
                            .padding(7)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}

/// Appearance choices behind the rail's settings button.
struct SettingsMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Picker("Appearance", selection: Binding(get: { app.appearance }, set: { app.appearance = $0 })) {
                Text("Match the system").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
            .pickerStyle(.inline)
            Picker("Default order", selection: Binding(get: { app.defaultOrder }, set: { app.defaultOrder = $0 })) {
                ForEach(DefaultOrder.allCases, id: \.self) { order in
                    Text(L10n.core(order.title)).tag(order)
                }
            }
            .pickerStyle(.inline)
            Picker("Language", selection: Binding(get: { AppLanguage.current }, set: { AppLanguage.choose($0) })) {
                Text("Match the system").tag(AppLanguage.system)
                ForEach(AppLanguage.allCases.filter { $0 != .system }, id: \.self) { language in
                    Text(verbatim: language.name).tag(language)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Connect Agents…") { app.showAgents = true }
        } label: {
            IconView(.settings, size: 14)
                .font(.system(size: 15))
                .foregroundStyle(Color.tmMuted)
                .frame(width: 38, height: 38)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 38, height: 38)
        .help("Settings")
    }
}

// MARK: - Window

/// Hands the hosting `NSWindow` to a closure once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowProbe()
        view.onWindow = configure
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowProbe: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Title bar styling: content runs under a transparent title bar and the traffic lights sit in
/// the middle of the app's own 48-point header.
@MainActor
enum WindowChrome {
    static let headerHeight: CGFloat = 48
    static let trafficLightsWidth: CGFloat = 86
    private static var observed = Set<ObjectIdentifier>()

    static func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.backgroundColor = .tmWindow
        placeTrafficLights(in: window)
        let id = ObjectIdentifier(window)
        guard !observed.contains(id) else { return }
        observed.insert(id)
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { placeTrafficLights(in: window) }
            }
        }
    }

    static func placeTrafficLights(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        var frame = container.frame
        frame.size.height = headerHeight
        frame.origin.y = window.frame.height - headerHeight
        container.frame = frame
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 16 + CGFloat(index) * 20, y: (headerHeight - button.frame.height) / 2))
        }
    }
}
