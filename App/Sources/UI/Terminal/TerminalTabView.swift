import SwiftUI
import AppCore
import CoreModels
import SSHCore

/// A terminal tab: the disconnected banner (when the session ended), the terminal (with the Change
/// Theme or Snippets panel over its right edge), and sheets for the host key and password prompts.
/// The tab's theme and text size follow the host's and its groups' themes, Settings → Terminal and
/// the system appearance live (see `resolvedAppearance`).
struct TerminalTabView: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let store: TerminalViewStore
    let vault: LocalVault
    let terminalSettings: TerminalSettings
    /// Closes this tab, the same as Cmd+W.
    let closeTab: () -> Void
    /// The side panel open over the terminal's right edge (Change Theme or Snippets), at most one.
    var sidePanel: TerminalSidePanel.Kind?
    var closeSidePanel: () -> Void = {}
    /// Opens this tab's host in Host Details; nil hides "Edit host" on the connection screen
    /// (windows without Vaults).
    var editHost: (() -> Void)?
    /// Opens a snippet in the Snippets screen (Edit, New Snippet in the snippets panel); nil hides
    /// both (windows without Vaults).
    var editSnippet: ((UUID) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let appearance = resolvedAppearance
        VStack(spacing: 0) {
            if case .disconnected(let message) = tab.state, !isAutoReconnecting, !showsConnectionScreen {
                DisconnectedBanner(message: bannerMessage(message),
                                   showsOnePasswordSetup: tab.suggestedAction == .openOnePasswordSetup) {
                    sessions.reconnect(tabID: tab.id)
                }
            }
            SwiftTermView(tab: tab, sessions: sessions, store: store, appearance: appearance)
                .padding(.leading, 8)
                .padding(.top, 4)
                // Over the terminal (which stays in place: its size starts the session) until the
                // session is up; fades away on .connected.
                .overlay {
                    if showsConnectionScreen {
                        ConnectionScreen(tab: tab, vault: vault, appearance: appearance,
                                         editHost: tab.savedHostID == nil ? nil : editHost,
                                         startOver: { sessions.reconnect(tabID: tab.id) },
                                         close: closeTab)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: showsConnectionScreen)
                // The countdown to the next try, bottom left (as in Termius), over the terminal or the
                // failed screen; while a try runs, the connection screen shows it instead.
                .overlay(alignment: .bottomLeading) {
                    if let state = tab.autoReconnect, case .waiting = state {
                        ReconnectPopup(
                            state: state,
                            // This window's tabs only: other windows have their own popups.
                            sessionCount: sessions.waitingForReconnectCount(inWindow: tab.windowID),
                            reconnectNow: { sessions.reconnectWaitingNow(inWindow: tab.windowID) },
                            closeTerminal: closeTab,
                            dismiss: { sessions.stopAutoReconnect(tabID: tab.id) }
                        )
                        .padding(12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: isWaitingForTry)
                // Only behind the terminal: the disconnected banner keeps the system look, so its
                // text stays readable when the theme and Light/Dark Mode differ.
                .background(appearance.theme.background.swiftUIColor)
                // Over the terminal only, below the disconnected banner (its Reconnect stays usable).
                .overlay(alignment: .trailing) {
                    switch sidePanel {
                    case .theme:
                        ThemeSidePanel(tab: tab, sessions: sessions, vault: vault,
                                       terminalSettings: terminalSettings, close: closeSidePanel)
                            .transition(.move(edge: .trailing))
                    case .snippets:
                        SnippetsSidePanel(tab: tab, sessions: sessions, vault: vault,
                                          editSnippet: editSnippet,
                                          focusTerminal: { store.focus(tabID: tab.id) },
                                          pasteIntoTerminal: { store.paste($0, tabID: tab.id) },
                                          isBracketedPasteActive: { store.isBracketedPasteActive(tabID: tab.id) },
                                          close: closeSidePanel)
                            .transition(.move(edge: .trailing))
                    case .history:
                        HistorySidePanel(tab: tab, sessions: sessions, vault: vault,
                                         editSnippet: editSnippet,
                                         focusTerminal: { store.focus(tabID: tab.id) },
                                         pasteIntoTerminal: { store.paste($0, tabID: tab.id) },
                                         isBracketedPasteActive: { store.isBracketedPasteActive(tabID: tab.id) },
                                         close: closeSidePanel)
                            .transition(.move(edge: .trailing))
                    case nil:
                        EmptyView()
                    }
                }
                .clipped()
                .animation(.easeOut(duration: 0.2), value: sidePanel)
        }
        .sheet(item: promptBinding) { prompt in
            promptSheet(prompt)
                .interactiveDismissDisabled()
        }
    }

    // MARK: Appearance

    /// The tab's own theme (`themeOverrideID`, set from the theme panel for quick connect) when the
    /// catalog knows it, else host theme → group chain → app default → Automatic (by the color scheme), and the text
    /// size. Reading `vault.revision`, the settings and `colorScheme` here makes Observation
    /// re-run the body (and so `SwiftTermView.updateNSView`) when any of them changes: a Settings
    /// click, a Host Details edit, a group menu choice, a sync from another Mac, or Light/Dark.
    /// Only the tab's own host is decoded (not every saved host); a deleted host reads as nil and
    /// gets the app default, as does quick connect.
    ///
    /// Same rule as `SessionManager.themeChoice` (what the theme panel rings): the tab's override wins,
    /// then the host's choice, a pending (not yet saved) one from the panel first.
    private var resolvedAppearance: TerminalAppearance {
        _ = vault.revision
        if let overrideID = tab.themeOverrideID, let theme = TerminalThemeCatalog.shared.theme(id: overrideID) {
            return terminalSettings.appearance(theme: theme)
        }
        var host = tab.savedHostID.flatMap { vault.get(SavedHost.self, id: $0) }
        if let id = host?.id, let pending = sessions.pendingTheme(forHost: id) { host?.themeID = pending.themeID }
        let theme = TerminalThemeResolver.theme(
            forHostID: tab.savedHostID,
            hosts: host.map { [$0] } ?? [],
            groups: host == nil ? [] : vault.all(HostGroup.self),
            defaultThemeID: terminalSettings.defaultThemeID,
            prefersDark: colorScheme == .dark
        )
        return terminalSettings.appearance(theme: theme)
    }

    // MARK: Connection screen

    /// While connecting (host key and password sheets come over it), and after a failure of an
    /// attempt that never connected. Reconnecting on its own, as in Termius: the first countdown after
    /// a drop keeps the terminal (old text) in view; each try shows this screen, a failed try its
    /// red log (with the countdown to the next try over it), and giving up the same with Start over.
    /// Once a try gets in, the screen fades into the terminal (old text kept, new login below).
    private var showsConnectionScreen: Bool {
        switch tab.autoReconnect {
        case .reconnecting, .gaveUp: return true
        case .waiting(let attempt, _, _): return attempt > 1 // a try already failed
        case nil: break
        }
        switch tab.state {
        case .connecting, .awaitingHostKey, .awaitingPassword: return true
        // A tab that was live once keeps its scrollback and the banner (incl. "Couldn't reconnect…").
        case .disconnected: return !tab.hadLiveSession
        case .connected: return false
        }
    }

    // MARK: Auto-reconnect

    private var isWaitingForTry: Bool {
        if case .waiting = tab.autoReconnect { return true }
        return false
    }

    /// The popup (not the banner) is up while a countdown or an automatic try is running.
    private var isAutoReconnecting: Bool {
        switch tab.autoReconnect {
        case .waiting, .reconnecting: true
        case .gaveUp, nil: false
        }
    }

    /// After the last automatic try the banner says so, instead of the bare error.
    private func bannerMessage(_ message: String?) -> String? {
        if case .gaveUp(let attempts) = tab.autoReconnect {
            return "Couldn\u{2019}t reconnect after \(attempts) \(attempts == 1 ? "try" : "tries")."
        }
        return message
    }

    // MARK: Prompts

    /// The sheet follows the tab's state; it closes when the state moves on. Only the sheet's own
    /// buttons answer, so the setter has nothing to do.
    /// In a workspace only one pane shows its question at a time (`Workspace.promptingPaneID`): the
    /// others wait with their amber dot, so the window never stacks several sheets.
    private var promptBinding: Binding<TerminalPrompt?> {
        Binding(get: {
            if let workspace = sessions.workspace(containing: tab.id), workspace.promptingPaneID != tab.id {
                return nil
            }
            return TerminalPrompt(state: tab.state)
        }, set: { _ in })
    }

    @ViewBuilder
    private func promptSheet(_ prompt: TerminalPrompt) -> some View {
        switch prompt {
        case .hostKey(let candidate, let check):
            HostKeyPrompt(candidate: candidate, check: check) { decision in
                sessions.answerHostKey(tabID: tab.id, decision)
            }
        case .password(let text):
            PasswordPrompt(prompt: text, canSave: tab.canSavePassword) { password, save in
                sessions.providePassword(tabID: tab.id, password, save: save)
            } cancel: {
                sessions.cancelPasswordPrompt(tabID: tab.id)
            }
        }
    }
}

/// A panel over a terminal tab's right edge. One at a time per window: opening Snippets closes
/// Change Theme and vice versa; switching or closing the tab closes it (`RootView`).
struct TerminalSidePanel: Equatable {
    enum Kind: Equatable {
        case theme
        case snippets
        case history
    }

    let tabID: UUID
    let kind: Kind
}

/// Cmd+. (Session menu): shows or hides the snippets panel of the focused window's selected terminal
/// tab. Published by every window (`focusedSceneValue`); `toggle` is nil while Vaults is selected.
struct SnippetsPanelToggle {
    var isOpen = false
    var toggle: (@MainActor () -> Void)?
}

private struct SnippetsPanelToggleKey: FocusedValueKey {
    typealias Value = SnippetsPanelToggle
}

/// Cmd+Y (Session menu): the same for the shell history panel.
private struct HistoryPanelToggleKey: FocusedValueKey {
    typealias Value = SnippetsPanelToggle
}

extension FocusedValues {
    var snippetsPanelToggle: SnippetsPanelToggle? {
        get { self[SnippetsPanelToggleKey.self] }
        set { self[SnippetsPanelToggleKey.self] = newValue }
    }

    var historyPanelToggle: SnippetsPanelToggle? {
        get { self[HistoryPanelToggleKey.self] }
        set { self[HistoryPanelToggleKey.self] = newValue }
    }
}

/// What the tab is asking the user, derived from its state.
enum TerminalPrompt: Identifiable {
    case hostKey(HostKeyCandidate, HostKeyCheck)
    case password(String)

    init?(state: TerminalTab.State) {
        switch state {
        case .awaitingHostKey(let candidate, let check):
            self = .hostKey(candidate, check)
        case .awaitingPassword(let prompt):
            self = .password(prompt)
        case .connecting, .connected, .disconnected:
            return nil
        }
    }

    /// A new prompt (another key, another password question) gets a new sheet.
    var id: String {
        switch self {
        case .hostKey(let candidate, let check):
            "hostKey|\(candidate.hostPort)|\(candidate.keyType)|\(candidate.fingerprint)|\(check)"
        case .password(let prompt):
            "password|\(prompt)"
        }
    }
}
