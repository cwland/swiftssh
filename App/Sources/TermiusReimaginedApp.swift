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
/// closes the selected tab, or a workspace's focused pane (or the window on Vaults), Cmd+1 shows Vaults,
/// Cmd+2…9 select tab bar items (a workspace counts as one), Cmd+Shift+[ / ] the previous and next item,
/// Cmd+R reconnects a disconnected tab, Cmd+. shows or hides the selected tab's snippets panel. In a
/// workspace: Cmd+B broadcast input, Cmd+Shift+M Focus mode / Split view, Cmd+S Save Workspace.
private struct SessionCommands: Commands {
    let environment: AppEnvironment
    @FocusedValue(\.windowScope) private var scope
    @FocusedValue(\.snippetsPanelToggle) private var snippetsPanel
    @FocusedValue(\.historyPanelToggle) private var historyPanel

    var body: some Commands {
        // Replaces the standard File > Close (Cmd+W).
        CommandGroup(replacing: .saveItem) {
            Button(workspace == nil ? "Close" : "Close Pane") {
                environment.closeSelectedTabOrWindow(in: scope)
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Save Workspace") {
                do {
                    try environment.saveSelectedWorkspace(in: scope)
                } catch {
                    environment.presentCommandError(error, title: "The workspace couldn\u{2019}t be saved")
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(workspace == nil)
        }
        CommandMenu("Workspace") {
            Button(workspace?.isBroadcasting == true ? "Stop Broadcasting Input" : "Broadcast Input") {
                environment.toggleBroadcast(in: scope)
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(workspace == nil)
            Button(workspace?.viewMode == .focus ? "Split View" : "Focus Mode") {
                environment.toggleViewMode(in: scope)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(workspace == nil)
            Divider()
            Button("Split Right") {
                split(at: .right)
            }
            .disabled(plainTab == nil)
            Button("Split Down") {
                split(at: .bottom)
            }
            .disabled(plainTab == nil)
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
            Button(historyPanel?.isOpen == true ? "Hide History" : "Show History") {
                historyPanel?.toggle?()
            }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(historyPanel?.toggle == nil)
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

    /// The workspace shown in the focused window, if any.
    private var workspace: Workspace? {
        environment.selectedWorkspace(in: environment.commandScope(scope))
    }

    /// The focused window's selected tab when it is a plain tab (Split Right / Down need one).
    private var plainTab: TerminalTab? {
        workspace == nil ? environment.selectedTab(in: environment.commandScope(scope)) : nil
    }

    private func split(at edge: DropEdge) {
        guard let tab = plainTab else { return }
        do {
            try environment.splitTab(tab.id, at: edge)
        } catch {
            environment.presentCommandError(error, title: "The tab couldn\u{2019}t be split")
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
