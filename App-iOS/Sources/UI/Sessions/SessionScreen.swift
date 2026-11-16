import SwiftUI
import AppCore
import CoreModels
import SSHCore
import SwiftSSHUI

/// A session, full screen: a header (iPhone: back to Hosts, the session switcher pill and close;
/// iPad: the session's name), then the terminal with the key bar above the keyboard. The connection
/// screen covers the terminal while connecting and after a failed first attempt; a dropped live
/// session keeps its scrollback under a banner. Host key and password questions come as sheets.
/// The terminal follows the host's (or its groups') theme and this device's text size.
struct SessionScreen: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let vault: LocalVault
    @Environment(IOSEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsSnippets = false

    var body: some View {
        let appearance = resolvedAppearance
        VStack(spacing: 0) {
            header
                .sheet(isPresented: $showsSnippets, onDismiss: {
                    environment.terminalViews.focus(tabID: tab.id)
                }) {
                    SnippetsDrawer(tab: tab, vault: vault, deliver: deliver)
                }
            if let banner = TerminalTabPresentation.banner(state: tab.state, autoReconnect: tab.autoReconnect,
                                                           hadLiveSession: tab.hadLiveSession) {
                DisconnectedBanner(message: banner, suggestedAction: tab.suggestedAction,
                                   reconnect: reconnect, importKey: importKey)
            }
            TerminalContainerView(tab: tab, sessions: sessions, store: environment.terminalViews,
                                  appearance: appearance,
                                  changeFontSize: { environment.terminalSettings.fontSize = $0 })
                .padding(.leading, 4)
                .background(appearance.theme.background.swiftUIColor)
                .sheet(item: fillBinding) { request in
                    if let snippet = vault.get(Snippet.self, id: request.snippetID) {
                        PlaceholderFormSheet(template: SnippetTemplate(snippet.script), actionTitle: "Run") { text in
                            environment.snippetToFill = nil
                            deliver(text, .run)
                        } onCancel: {
                            environment.snippetToFill = nil
                        }
                    }
                }
                .overlay {
                    if showsConnectionScreen {
                        ConnectionScreen(tab: tab, vault: vault, startOver: reconnect,
                                         close: { sessions.close(tabID: tab.id) }, importKey: importKey)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: showsConnectionScreen)
                .overlay(alignment: .bottom) {
                    if case .waiting(_, let deadline, _) = tab.autoReconnect {
                        ReconnectCountdown(deadline: deadline,
                                           reconnectNow: { sessions.reconnectWaitingNow(inWindow: nil) },
                                           stop: { sessions.stopAutoReconnect(tabID: tab.id) })
                            .padding(12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .sheet(item: promptBinding) { prompt in
            promptSheet(prompt)
                .interactiveDismissDisabled()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if sizeClass != .regular {
                Button {
                    sessions.selectedTabID = nil
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Hosts")
                Spacer(minLength: 0)
                Menu {
                    SessionMenuItems(sessions: sessions)
                } label: {
                    HStack(spacing: 6) {
                        SessionStatusDot(tab: tab)
                        Text(tab.displayTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.tabBackground))
                }
                .accessibilityLabel("Switch session")
                Spacer(minLength: 0)
            } else {
                SessionStatusDot(tab: tab)
                Text(tab.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            trailingButtons
        }
        .foregroundStyle(Theme.topBarForeground)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.topBarBackground)
    }

    @ViewBuilder
    private var trailingButtons: some View {
        Button {
            environment.terminalViews.toggleKeyboard(tabID: tab.id)
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Show or hide keyboard")
        // The system Paste button: reads the clipboard (including Universal Clipboard from a Mac)
        // without the "Allow Paste" prompt, and pastes it into the session as typed-in text would be.
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first, !text.isEmpty else { return }
            Task { @MainActor in deliver(text, .paste) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Theme.topBarForeground)
        .controlSize(.small)
        Button {
            showsSnippets = true
        } label: {
            Image(systemName: "text.alignleft")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Snippets")
        if sizeClass != .regular {
            Button {
                sessions.close(tabID: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Close session")
        }
    }

    // MARK: Snippets

    /// Paste goes through the terminal (bracketed paste when the shell asked for it); Run types the
    /// text and Return.
    private func deliver(_ text: String, _ delivery: SnippetDelivery) {
        switch delivery {
        case .paste:
            if !environment.terminalViews.paste(text, tabID: tab.id) {
                sessions.deliver(text, as: .paste, toTab: tab.id)
            }
        case .run:
            sessions.deliver(text, as: .run, toTab: tab.id)
        }
    }

    /// A snippet chosen on the Snippets screen for this session, waiting for its placeholder values.
    private var fillBinding: Binding<SnippetRequest?> {
        Binding(get: { environment.snippetToFill.flatMap { $0.tabID == tab.id ? $0 : nil } },
                set: { if $0 == nil { environment.snippetToFill = nil } })
    }

    // MARK: State

    private var showsConnectionScreen: Bool {
        TerminalTabPresentation.showsConnectionScreen(state: tab.state, autoReconnect: tab.autoReconnect,
                                                      hadLiveSession: tab.hadLiveSession)
    }

    private func reconnect() {
        Task { await environment.reconnect(tabID: tab.id) }
    }

    private func importKey() {
        sessions.selectedTabID = nil
        environment.navigation.show(.keys)
    }

    /// The theme chosen in Settings for every session (host and group themes from the Mac aren't
    /// used on iPhone/iPad), else Automatic by the colour scheme; and this device's text size.
    /// Reading the settings and the colour scheme here re-applies them live.
    private var resolvedAppearance: TerminalAppearance {
        let settings = environment.terminalSettings
        let theme = CompanionThemes.theme(selectedID: settings.defaultThemeID, prefersDark: colorScheme == .dark)
        return settings.appearance(theme: theme)
    }

    // MARK: Prompts

    /// The sheet follows the session's state; it closes when the state moves on. Only the sheet's
    /// own buttons answer.
    private var promptBinding: Binding<SessionPrompt?> {
        Binding(get: { SessionPrompt(state: tab.state) }, set: { _ in })
    }

    @ViewBuilder
    private func promptSheet(_ prompt: SessionPrompt) -> some View {
        switch prompt {
        case .hostKey(let candidate, let check):
            HostKeyPromptSheet(candidate: candidate, check: check) { decision in
                sessions.answerHostKey(tabID: tab.id, decision)
            }
        case .password(let text):
            PasswordPromptSheet(prompt: text,
                                info: CompanionConnect.passwordPrompt(hostID: tab.savedHostID, vault: vault)) { password in
                sessions.providePassword(tabID: tab.id, password, save: false)
            } cancel: {
                sessions.cancelPasswordPrompt(tabID: tab.id)
            }
        }
    }
}
