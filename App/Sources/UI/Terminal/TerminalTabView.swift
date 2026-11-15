import SwiftUI
import AppCore
import CoreModels
import SSHCore

/// A terminal tab: the disconnected banner (when the session ended), the terminal, and sheets for
/// the host key and password prompts. The tab's theme and text size follow the host's and its
/// groups' themes, Settings → Terminal and the system appearance live (see `resolvedAppearance`).
struct TerminalTabView: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let store: TerminalViewStore
    let vault: LocalVault
    let terminalSettings: TerminalSettings
    /// Closes this tab, the same as Cmd+W.
    let closeTab: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let appearance = resolvedAppearance
        VStack(spacing: 0) {
            if case .disconnected(let message) = tab.state, !isAutoReconnecting {
                DisconnectedBanner(message: bannerMessage(message),
                                   showsOnePasswordSetup: tab.suggestedAction == .openOnePasswordSetup) {
                    sessions.reconnect(tabID: tab.id)
                }
            }
            SwiftTermView(tab: tab, sessions: sessions, store: store, appearance: appearance)
                .padding(.leading, 8)
                .padding(.top, 4)
                .overlay(alignment: .top) {
                    if tab.state == .connecting, !isAutoReconnecting {
                        ConnectingBadge(title: tab.title)
                            .padding(.top, 12)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let state = tab.autoReconnect, isAutoReconnecting {
                        ReconnectPopup(
                            state: state,
                            sessionCount: sessions.waitingForReconnectCount,
                            reconnectNow: { sessions.reconnectWaitingNow() },
                            closeTerminal: closeTab,
                            dismiss: { sessions.stopAutoReconnect(tabID: tab.id) }
                        )
                        .padding(12)
                    }
                }
                // Only behind the terminal: the disconnected banner keeps the system look, so its
                // text stays readable when the theme and Light/Dark Mode differ.
                .background(appearance.theme.background.swiftUIColor)
        }
        .sheet(item: promptBinding) { prompt in
            promptSheet(prompt)
                .interactiveDismissDisabled()
        }
    }

    // MARK: Appearance

    /// Host theme → group chain → app default → Automatic (by the color scheme), and the text
    /// size. Reading `vault.revision`, the settings and `colorScheme` here makes Observation
    /// re-run the body (and so `SwiftTermView.updateNSView`) when any of them changes: a Settings
    /// click, a Host Details edit, a group menu choice, a sync from another Mac, or Light/Dark.
    /// Only the tab's own host is decoded (not every saved host); a deleted host reads as nil and
    /// gets the app default, as does quick connect.
    private var resolvedAppearance: TerminalAppearance {
        _ = vault.revision
        let host = tab.savedHostID.flatMap { vault.get(SavedHost.self, id: $0) }
        let theme = TerminalThemeResolver.theme(
            forHostID: tab.savedHostID,
            hosts: host.map { [$0] } ?? [],
            groups: host == nil ? [] : vault.all(HostGroup.self),
            defaultThemeID: terminalSettings.defaultThemeID,
            prefersDark: colorScheme == .dark
        )
        return TerminalAppearance(theme: theme, fontSize: terminalSettings.fontSize)
    }

    // MARK: Auto-reconnect

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
    private var promptBinding: Binding<TerminalPrompt?> {
        Binding(get: { TerminalPrompt(state: tab.state) }, set: { _ in })
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

/// "Connecting to <host>…" over the top of a terminal that has no session yet.
private struct ConnectingBadge: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Connecting to \(title.isEmpty ? "host" : title)…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}
