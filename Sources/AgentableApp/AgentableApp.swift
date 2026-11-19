import AppKit
import SwiftUI
import AgentableCore

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--seed-demo"), index + 1 < arguments.count {
            exit(DemoData.seedFromCommandLine(arguments[index + 1]))
        }
        Fonts.register()
        AgentableMain.main()
    }
}

struct AgentableMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppDelegate.makeModel()

    /// The SQL tab on screen, if one is.
    private var sqlTab: SQLDocument? {
        guard let workspace = model?.workspace, let table = workspace.currentTable,
              let grid = workspace.openGrid(table), grid.viewTab == .sql else { return nil }
        return grid.sql
    }

    var body: some Scene {
        Window("Agentable", id: "main") {
            Group {
                if let model {
                    RootView()
                        .environment(model)
                } else {
                    StartupFailureView(message: AppDelegate.startupError ?? String(localized: "Unknown error"))
                }
            }
            .environment(\.locale, L10n.locale)
            .frame(minWidth: 1080, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1376, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Changes") {
                Button("Save") { model?.workspace?.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model?.workspace?.changeCount ?? 0 == 0)
                Button("Reload") { model?.workspace?.reloadCurrent() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Add Row") { model?.workspace?.addRow() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(model?.workspace?.currentTable == nil || sqlTab != nil)
            }
            CommandMenu("Query") {
                Button("Run Statement") { sqlTab?.run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sqlTab == nil)
                Button("Ask an Agent…") { sqlTab?.askRequested = true }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(sqlTab == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Show Agent Session") { model?.workspace?.showSession.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var startupError: String?

    @MainActor static func makeModel() -> AppModel? {
        Defaults.moveLegacyPreferences()
        do {
            let model = try AppModel()
            NSApp?.appearance = model.appearance.nsAppearance
            if let forced = ProcessInfo.processInfo.environment["AGENTABLE_APPEARANCE"], let appearance = Appearance(rawValue: forced) {
                NSApp?.appearance = appearance.nsAppearance
            }
            return model
        } catch {
            startupError = "\(error)"
            return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.isActive {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// An agent asked from the SQL tab stops with the app.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AskRun.stopAll() }
    }
}

struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Text("Agentable could not start").font(.ui(17, .semibold))
            Text(message).font(.mono(12)).foregroundStyle(Color.tmMuted).textSelection(.enabled)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tmWindow)
    }
}
