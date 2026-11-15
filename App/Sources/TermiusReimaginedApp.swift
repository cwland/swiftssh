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
        }

        // Cmd+, — Termius-style sidebar of panes (Connection, Sync, 1Password, OS Icons).
        Settings {
            SettingsView(connectionSettings: environment.connectionSettings,
                         navigation: environment.settingsNavigation,
                         onePassword: environment.onePassword,
                         sync: environment.sync,
                         vault: environment.vault)
                .environment(environment.settingsNavigation)
                .environment(environment.onePassword)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Keyboard commands for terminal tabs: Cmd+W closes the selected tab (or the window on
/// Vaults), Cmd+1 shows Vaults, Cmd+2…9 select tabs, Cmd+R reconnects a disconnected tab.
private struct SessionCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        // Replaces the standard File > Close (Cmd+W).
        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                environment.closeSelectedTabOrWindow()
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        CommandMenu("Session") {
            Button("Reconnect") {
                environment.reconnectSelectedTab()
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Vaults") {
                environment.selectTab(number: 1)
            }
            .keyboardShortcut("1", modifiers: .command)
            ForEach(2...9, id: \.self) { number in
                Button("Session \(number - 1)") {
                    environment.selectTab(number: number)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
    }
}
