import SwiftUI
import AppKit
import AppCore

/// Opens a terminal window ("Duplicate in New Window"): its own id (its tabs' `windowID`) and the tab
/// to duplicate into it once it appears. Shown by the app's `WindowGroup(id: sceneID, for:)`.
struct TerminalWindowRequest: Codable, Hashable {
    static let sceneID = "terminal"

    var windowID = UUID()
    var sourceTabID: UUID
}

/// Which window's tabs menu commands act on: the focused scene's (`focusedSceneValue`).
struct WindowScope: Hashable {
    /// nil = the main window (Vaults and the main tabs).
    let windowID: UUID?

    /// A "Duplicate in New Window" window: terminal tabs only, no Vaults.
    var isTerminalWindow: Bool { windowID != nil }
}

private struct WindowScopeKey: FocusedValueKey {
    typealias Value = WindowScope
}

extension FocusedValues {
    var windowScope: WindowScope? {
        get { self[WindowScopeKey.self] }
        set { self[WindowScopeKey.self] = newValue }
    }
}

/// Top bar over the selected tab: Vaults (sidebar + content) or a terminal session. The top bar
/// extends into the hidden title bar's area.
///
/// Windows: the main window (and Cmd+N copies of it) shows Vaults and the main tabs; a terminal window
/// shows only its own tabs (`windowID`) and closes when its last tab closes. Every window publishes its
/// `WindowScope` for menu commands (and registers it with its NSWindow as the fallback). Closing a terminal
/// window ends its sessions; closing main windows leaves the main tabs running, as in v0.6.0.
struct RootView: View {
    let environment: AppEnvironment
    var windowRequest: TerminalWindowRequest? = nil
    var isTerminalWindow = false

    @Environment(\.openWindow) private var openWindow
    /// The tab whose Change Theme panel is open.
    @State private var themePanelTabID: UUID?
    @State private var didOpenRequestedTab = false
    /// The duplicate could not be opened (its source tab is gone): the window closes as soon as it is known.
    @State private var openFailed = false
    @State private var window = WindowReference()

    private var windowID: UUID? { windowRequest?.windowID }

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(
                navigation: environment.navigation,
                sessions: environment.sessions,
                sync: environment.sync,
                windowID: windowID,
                showsVaults: !isTerminalWindow,
                selectVaults: { environment.showVaults() },
                closeTab: { environment.closeTab(tabID: $0) },
                changeTheme: { tabID in
                    environment.sessions?.select(tabID: tabID, inWindow: windowID)
                    themePanelTabID = tabID
                },
                duplicateInNewWindow: { tabID in
                    openWindow(id: TerminalWindowRequest.sceneID, value: TerminalWindowRequest(sourceTabID: tabID))
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
                                  windowID: windowID, isTerminalWindow: isTerminalWindow,
                                  themePanelTabID: $themePanelTabID)
                    }
                case .failed(let failure):
                    VaultErrorView(failure: failure) {
                        Task { await environment.retry() }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .focusedSceneValue(\.windowScope, WindowScope(windowID: windowID))
        .background {
            WindowLifecycleObserver(
                attached: { nsWindow in
                    window.window = nsWindow
                    environment.windowAttached(nsWindow, scope: WindowScope(windowID: windowID))
                    if openFailed { closeLater(nsWindow) }
                },
                willClose: { nsWindow in
                    environment.windowClosed(nsWindow, scope: WindowScope(windowID: windowID))
                }
            )
        }
        // A terminal window opens its duplicate once the sessions exist.
        .task(id: environment.sessions == nil) {
            guard isTerminalWindow, !didOpenRequestedTab, let sessions = environment.sessions else { return }
            didOpenRequestedTab = true
            guard let request = windowRequest,
                  sessions.duplicate(tabID: request.sourceTabID, inWindow: request.windowID) != nil else {
                // The source tab closed meanwhile: nothing to show. If the window isn't known yet,
                // `attached` closes it.
                openFailed = true
                if let nsWindow = window.window { closeLater(nsWindow) }
                return
            }
        }
        // A terminal window has no Vaults: it closes with its last tab.
        .onChange(of: environment.sessions?.tabs(inWindow: windowID).isEmpty ?? true) { _, isEmpty in
            if isTerminalWindow, didOpenRequestedTab, isEmpty, let nsWindow = window.window, nsWindow.isVisible {
                nsWindow.close()
            }
        }
    }
}

/// Closes the window after the current update (not from inside a view update or `viewDidMoveToWindow`).
@MainActor
private func closeLater(_ window: NSWindow) {
    Task { @MainActor in
        if window.isVisible { window.close() }
    }
}

/// The window a `RootView` is in, once known (for closing a terminal window from code).
@MainActor
private final class WindowReference {
    weak var window: NSWindow?
}

/// Reports the window the view is placed in, and that window's `willCloseNotification`: the
/// reliable "window closed" signal (`onDisappear` also fires for other view teardown). The observer is
/// removed when the view leaves its window, so a recreated view never leaves a stale one behind;
/// reporting the same window again is harmless (registration is keyed by window).
private struct WindowLifecycleObserver: NSViewRepresentable {
    let attached: @MainActor (NSWindow) -> Void
    let willClose: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.attached = attached
        view.willClose = willClose
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.attached = attached
        view.willClose = willClose
    }

    final class ObserverView: NSView {
        var attached: (@MainActor (NSWindow) -> Void)?
        var willClose: (@MainActor (NSWindow) -> Void)?
        private weak var observedWindow: NSWindow?
        private var token: (any NSObjectProtocol)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow !== observedWindow { stopObserving() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== observedWindow else { return }
            observedWindow = window
            token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                           object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.observedWindow else { return }
                    self.stopObserving()
                    self.willClose?(window)
                }
            }
            attached?(window)
        }

        private func stopObserving() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            observedWindow = nil
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
    let isTerminalWindow: Bool
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
                                closeThemePanel: { themePanelTabID = nil },
                                editHost: isTerminalWindow ? nil : { editHost(of: tab) })
                    .id(tab.id)
            } else if isTerminalWindow {
                // Only while the window opens or closes.
                Theme.contentBackground
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

    /// "Edit host" on the connection screen: Vaults → Hosts with the tab's host selected (its Host
    /// Details panel opens). The tab stays open. Main window only.
    private func editHost(of tab: TerminalTab) {
        guard let hostID = tab.savedHostID else { return }
        environment.navigation.sidebar = .hosts
        hostsModel?.selectedHostID = hostID
        environment.showVaults()
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
