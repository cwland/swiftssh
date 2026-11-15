import SwiftUI
import AppCore

@main
struct TermiusReimaginedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .environment(environment.settingsNavigation)
                .environment(environment.onePassword)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    appDelegate.environment = environment
                    await environment.load()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        .commands {
            SessionCommands(environment: environment)
            TextSizeCommands(settings: environment.terminalSettings)
        }

        // "Duplicate in New Window": a window of terminal tabs only (no Vaults), opened with
        // `openWindow(id: "terminal", value:)`. Not restored at relaunch (its sessions are gone).
        WindowGroup(id: TerminalWindowRequest.sceneID, for: TerminalWindowRequest.self) { $request in
            RootView(environment: environment, windowRequest: request, isTerminalWindow: true)
                .environment(environment.settingsNavigation)
                .environment(environment.onePassword)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 700)
        .restorationBehavior(.disabled)

        // Cmd+, — Termius-style sidebar of panes (Connection, Terminal, Sync, 1Password, OS Icons).
        Settings {
            SettingsView(connectionSettings: environment.connectionSettings,
                         terminalSettings: environment.terminalSettings,
                         navigation: environment.settingsNavigation,
                         appearance: environment.appAppearance,
                         onePassword: environment.onePassword,
                         sync: environment.sync,
                         vault: environment.vault)
                .environment(environment.settingsNavigation)
                .environment(environment.onePassword)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Keyboard commands for terminal tabs, acting on the focused window's tabs (`WindowScope`): Cmd+W
/// closes the selected tab (or the window on Vaults), Cmd+1 shows Vaults, Cmd+2…9 select tabs,
/// Cmd+Shift+[ / ] the previous and next tab, Cmd+R reconnects a disconnected tab, Cmd+. shows or
/// hides the selected tab's snippets panel.
private struct SessionCommands: Commands {
    let environment: AppEnvironment
    @FocusedValue(\.windowScope) private var scope
    @FocusedValue(\.snippetsPanelToggle) private var snippetsPanel

    var body: some Commands {
        // Replaces the standard File > Close (Cmd+W).
        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                environment.closeSelectedTabOrWindow(in: scope)
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        CommandMenu("Session") {
            Button("Reconnect") {
                environment.reconnectSelectedTab(in: scope)
            }
            .keyboardShortcut("r", modifiers: .command)
            Button(snippetsPanel?.isOpen == true ? "Hide Snippets" : "Show Snippets") {
                snippetsPanel?.toggle?()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(snippetsPanel?.toggle == nil)
            Divider()
            Button("Show Previous Tab") {
                environment.selectAdjacentTab(by: -1, in: scope)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Show Next Tab") {
                environment.selectAdjacentTab(by: 1, in: scope)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
            Button("Vaults") {
                environment.selectTab(number: 1, in: scope)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(scope?.isTerminalWindow ?? false)
            ForEach(2...9, id: \.self) { number in
                Button("Session \(number - 1)") {
                    environment.selectTab(number: number, in: scope)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
    }
}

/// View menu text-size items: Bigger Text (Cmd+=), Smaller Text (Cmd+-) and Actual Size (Cmd+0).
/// Open terminal tabs follow `TerminalSettings.fontSize`, so these resize them live. Bigger and
/// Smaller disable at the ends of the 9\u{2013}24 pt range.
private struct TextSizeCommands: Commands {
    let settings: TerminalSettings

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Bigger Text") {
                settings.increaseFontSize()
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(!settings.canIncreaseFontSize)
            Button("Smaller Text") {
                settings.decreaseFontSize()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!settings.canDecreaseFontSize)
            Button("Actual Size") {
                settings.resetFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
