import SwiftUI
import AppCore

/// What a window opened by "Duplicate in New Window" shows: its own id (its tabs' `windowID`) and the
/// tab to duplicate into it once it appears. The app's `WindowGroup(for: TerminalWindowRequest.self)`
/// passes it to `RootView`; the launch window (and Cmd+N) get nil = the main window.
struct TerminalWindowRequest: Codable, Hashable {
    var windowID = UUID()
    var sourceTabID: UUID
}

/// Top bar over the selected tab: Vaults (sidebar + content) or a terminal session. The top bar
/// extends into the hidden title bar's area.
///
/// Windows: every window has its own tabs and selection in the shared `SessionManager`
/// (`windowID`, nil = the main window). The key window is the manager's `activeWindowID`, so menu
/// commands (Cmd+W, Cmd+R, …) act on it; closing a window opened for a duplicate closes its tabs.
struct RootView: View {
    let environment: AppEnvironment
    /// nil = the main window.
    var windowRequest: TerminalWindowRequest? = nil

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow
    /// The tab whose Change Theme panel is open.
    @State private var themePanelTabID: UUID?
    @State private var didOpenRequestedTab = false

    private var windowID: UUID? { windowRequest?.windowID }

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(
                navigation: environment.navigation,
                sessions: environment.sessions,
                sync: environment.sync,
                windowID: windowID,
                selectVaults: {
                    environment.sessions?.activeWindowID = windowID
                    environment.showVaults()
                },
                closeTab: { environment.closeTab(tabID: $0) },
                changeTheme: { tabID in
                    environment.sessions?.select(tabID: tabID, inWindow: windowID)
                    themePanelTabID = tabID
                },
                duplicateInNewWindow: { tabID in
                    openWindow(value: TerminalWindowRequest(sourceTabID: tabID))
                }
            )
            Group {
                switch environment.state {
                case .loading:
                    ProgressView("Opening vault…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.contentBackground)
                case .ready(let vault):
                    if let sessions = environment.sessions {
                        ReadyArea(environment: environment, vault: vault, sessions: sessions,
                                  windowID: windowID, themePanelTabID: $themePanelTabID)
                    }
                case .failed(let failure):
                    VaultErrorView(failure: failure) {
                        Task { await environment.retry() }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        // The key window's tabs are the ones menu commands and new connections act on.
        .onChange(of: appearsActive, initial: true) { _, active in
            if active { environment.sessions?.activeWindowID = windowID }
        }
        // Opens the duplicate once the sessions exist (the vault may still be opening).
        .task(id: environment.sessions == nil) {
            guard let request = windowRequest, !didOpenRequestedTab, let sessions = environment.sessions else { return }
            didOpenRequestedTab = true
            sessions.activeWindowID = request.windowID
            // A restored window whose source tab is gone (after a relaunch) just shows Vaults.
            sessions.duplicate(tabID: request.sourceTabID, inWindow: request.windowID)
        }
        .onDisappear {
            if let windowID { environment.sessions?.closeWindow(windowID) }
        }
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
    let windowID: UUID?
    @Binding var themePanelTabID: UUID?

    @State private var hostsModel: HostsViewModel?
    @State private var keychainModel: KeychainViewModel?
    @State private var logsModel: LogsViewModel?

    var body: some View {
        Group {
            if let tab = selectedTab {
                TerminalTabView(tab: tab, sessions: sessions, store: environment.terminalViews,
                                vault: vault, terminalSettings: environment.terminalSettings,
                                closeTab: { environment.closeTab(tabID: tab.id) },
                                showsThemePanel: themePanelTabID == tab.id,
                                closeThemePanel: { themePanelTabID = nil })
                    .id(tab.id)
            } else {
                MainArea(
                    navigation: environment.navigation,
                    vault: vault,
                    sessions: sessions,
                    terminalSettings: environment.terminalSettings,
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
            // Every window's tabs: a window must not drop another window's terminal views.
            environment.terminalViews.retain(only: Set(openIDs))
            if let id = themePanelTabID, !openIDs.contains(id) { themePanelTabID = nil }
        }
        // The panel belongs to the tab it was opened on; switching tabs closes it.
        .onChange(of: selectedTab?.id) { _, id in
            if themePanelTabID != id { themePanelTabID = nil }
        }
    }

    /// This window's selected tab; nil while Vaults is selected.
    private var selectedTab: TerminalTab? {
        guard let id = sessions.selectedTabID(inWindow: windowID) else { return nil }
        return sessions.tabs.first { $0.id == id }
    }
}

private struct MainArea: View {
    let navigation: AppNavigation
    let vault: LocalVault
    let sessions: SessionManager
    /// For Host Details' "Default (…)" theme label (passed on to `HostsView`).
    let terminalSettings: TerminalSettings
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
                HostsView(model: hostsModel, vault: vault, sessions: sessions, terminalSettings: terminalSettings)
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
