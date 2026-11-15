import SwiftUI
import AppCore

/// Top bar over the selected tab: Vaults (sidebar + content) or a terminal session. The top bar
/// extends into the hidden title bar's area.
struct RootView: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(
                navigation: environment.navigation,
                sessions: environment.sessions,
                sync: environment.sync,
                selectVaults: { environment.showVaults() },
                closeTab: { environment.closeTab(tabID: $0) }
            )
            Group {
                switch environment.state {
                case .loading:
                    ProgressView("Opening vault…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.contentBackground)
                case .ready(let vault):
                    if let sessions = environment.sessions {
                        ReadyArea(environment: environment, vault: vault, sessions: sessions)
                    }
                case .failed(let failure):
                    VaultErrorView(failure: failure) {
                        Task { await environment.retry() }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The open vault: the selected terminal tab, or the Vaults screens. Holds the Hosts, Keychain and Logs
/// view models so search, filters and the open group survive switching sidebar items and tabs.
/// They are built once, on appear, rather than in `init` (which runs on every parent body
/// evaluation).
private struct ReadyArea: View {
    let environment: AppEnvironment
    let vault: LocalVault
    let sessions: SessionManager

    @State private var hostsModel: HostsViewModel?
    @State private var keychainModel: KeychainViewModel?
    @State private var logsModel: LogsViewModel?

    var body: some View {
        Group {
            if let tab = environment.selectedTab {
                TerminalTabView(tab: tab, sessions: sessions, store: environment.terminalViews,
                                vault: vault, terminalSettings: environment.terminalSettings,
                                closeTab: { environment.closeTab(tabID: tab.id) })
                    .id(tab.id)
            } else {
                MainArea(
                    navigation: environment.navigation,
                    vault: vault,
                    sessions: sessions,
                    hostsModel: hostsModel,
                    keychainModel: keychainModel,
                    logsModel: logsModel
                )
            }
        }
        .onAppear {
            if hostsModel == nil {
                hostsModel = HostsViewModel(vault: vault)
            }
            if keychainModel == nil {
                keychainModel = KeychainViewModel(vault: vault)
            }
            if logsModel == nil {
                logsModel = LogsViewModel(vault: vault)
            }
        }
        .onChange(of: sessions.tabs.map(\.id)) { _, openIDs in
            environment.terminalViews.retain(only: Set(openIDs))
        }
    }
}

private struct MainArea: View {
    let navigation: AppNavigation
    let vault: LocalVault
    let sessions: SessionManager
    let hostsModel: HostsViewModel?
    let keychainModel: KeychainViewModel?
    let logsModel: LogsViewModel?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(navigation: navigation)
            Divider()
            VStack(spacing: 0) {
                if let error = vault.lastSaveError {
                    SaveErrorBanner(error: error) {
                        Task { await vault.flush() }
                    }
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.sidebar {
        case .hosts:
            if let hostsModel {
                HostsView(model: hostsModel, vault: vault, sessions: sessions)
            } else {
                Theme.contentBackground
            }
        case .keychain:
            if let keychainModel {
                KeychainView(model: keychainModel, vault: vault)
            } else {
                Theme.contentBackground
            }
        case .logs:
            if let logsModel {
                LogsView(model: logsModel)
            } else {
                Theme.contentBackground
            }
        case .snippets, .knownHosts:
            PlaceholderView("Coming in a later milestone")
        }
    }
}

/// Shown over the content while the vault's last write failed; goes away after the next
/// successful write.
private struct SaveErrorBanner: View {
    let error: any Error
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warningForeground)
            Text("Changes couldn't be saved: \(error.localizedDescription)")
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct VaultErrorView: View {
    let failure: AppEnvironment.LoadFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Your vault could not be opened")
                .font(.system(size: 17, weight: .semibold))
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560)
            }
            Button(buttonTitle, action: retry)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }

    private var paragraphs: [String] {
        switch failure {
        case .unreadable(let movedTo, let keyWasCreated):
            let reason = keyWasCreated
                ? "A new vault key was created because none was found in your Keychain, so the existing vault file couldn't be opened."
                : "The vault file could not be read."
            return [reason, "Your old data is kept at \(movedTo). Starting fresh creates a new, empty vault."]
        case .other(let message):
            return [message]
        }
    }

    private var buttonTitle: String {
        switch failure {
        case .unreadable: "Start with an Empty Vault"
        case .other: "Try Again"
        }
    }
}
