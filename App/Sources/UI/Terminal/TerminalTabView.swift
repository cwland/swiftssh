import SwiftUI
import AppCore
import SSHCore

/// A terminal tab: the disconnected banner (when the session ended), the terminal, and sheets for
/// the host key and password prompts.
struct TerminalTabView: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let store: TerminalViewStore

    var body: some View {
        VStack(spacing: 0) {
            if case .disconnected(let message) = tab.state {
                DisconnectedBanner(message: message) {
                    sessions.reconnect(tabID: tab.id)
                }
            }
            SwiftTermView(tab: tab, sessions: sessions, store: store)
                .padding(.leading, 8)
                .padding(.top, 4)
                .overlay(alignment: .top) {
                    if tab.state == .connecting {
                        ConnectingBadge(title: tab.title)
                            .padding(.top, 12)
                    }
                }
        }
        .background(TerminalTheme.dynamicBackground)
        .sheet(item: promptBinding) { prompt in
            promptSheet(prompt)
                .interactiveDismissDisabled()
        }
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
            PasswordPrompt(prompt: text) { password, save in
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
