import SwiftUI
import AppKit
import AppCore

/// Opens a terminal window: its own id (its tabs' `windowID`) and what to show once it appears, a
/// copy of the tab `sourceTabID` ("Duplicate in New Window"), a new tab for the saved host `hostID`
/// (Hosts → "Connect in a New Window"), or the saved workspace `templateID` (its "Open in a New
/// Window"). Shown by the app's `WindowGroup(id: sceneID, for:)`.
struct TerminalWindowRequest: Codable, Hashable {
    static let sceneID = "terminal"

    var windowID = UUID()
    var sourceTabID: UUID?
    var hostID: UUID?
    var templateID: UUID?
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
    /// The side panel (Change Theme or Snippets) open over one of this window's tabs.
    @State private var sidePanel: TerminalSidePanel?
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
                    sidePanel = TerminalSidePanel(tabID: tabID, kind: .theme)
                },
                showSnippets: { tabID in
                    environment.sessions?.select(tabID: tabID, inWindow: windowID)
                    sidePanel = TerminalSidePanel(tabID: tabID, kind: .snippets)
                },
                duplicateInNewWindow: { tabID in
                    openWindow(id: TerminalWindowRequest.sceneID, value: TerminalWindowRequest(sourceTabID: tabID))
                },
                workspaceTemplates: isTerminalWindow ? nil : environment.workspaceTemplates,
                selectItem: { environment.select($0, inWindow: windowID) },
                splitTab: { try environment.splitTab($0, at: $1) },
                saveWorkspace: { try environment.saveWorkspace($0) },
                closeWorkspace: { environment.closeWorkspace($0) },
                renameWorkspace: { try environment.renameWorkspace($0, to: $1) },
                asksToSaveWorkspaces: { environment.connectionSettings.askToSaveWorkspaces },
                hasSavedCopy: { environment.workspaceTemplates.hasSavedCopy(of: $0) },
                namingRequest: environment.namingWorkspaceID,
                clearNamingRequest: { environment.namingWorkspaceID = nil },
                openTemplate: { try environment.openWorkspaceTemplate($0) }
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
                                  sidePanel: $sidePanel)
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
            let opened: Bool
            if let request = windowRequest, let sourceTabID = request.sourceTabID {
                opened = sessions.duplicate(tabID: sourceTabID, inWindow: request.windowID) != nil
            } else if let request = windowRequest, let hostID = request.hostID {
                opened = (try? sessions.open(hostID: hostID, inWindow: request.windowID)) != nil
            } else if let request = windowRequest, let templateID = request.templateID,
                      let template = environment.workspaceTemplates.templates.first(where: { $0.id == templateID }) {
                opened = (try? sessions.openTemplate(template, inWindow: request.windowID)) != nil
            } else {
                opened = false
            }
            guard opened else {
                // The source tab closed (or the host went) meanwhile: nothing to show. If the window isn't known yet,
                // `attached` closes it.
                openFailed = true
                if let nsWindow = window.window { closeLater(nsWindow) }
                return
            }
        }
        // A terminal window has no Vaults: it closes with its last tab.
        // A tab that closed itself (the shell exited) lets go of its terminal view and scrollback.
        .onChange(of: environment.sessions?.tabs.count ?? 0) { old, new in
            if new < old { environment.releaseClosedTerminalViews() }
        }
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

/// The open vault: the selected terminal tab, or the Vaults screens. Holds the Hosts, Keychain, Logs and Snippets
/// view models so search, filters and the open group survive switching sidebar items and tabs.
/// They are built once, on appear, rather than in `init` (which runs on every parent body
/// evaluation).
private struct ReadyArea: View {
    let environment: AppEnvironment
    let vault: LocalVault
    let sessions: SessionManager
    let windowID: UUID?
    let isTerminalWindow: Bool
    @Binding var sidePanel: TerminalSidePanel?

    @State private var hostsModel: HostsViewModel?
    @State private var keychainModel: KeychainViewModel?
    @State private var logsModel: LogsViewModel?
    @State private var snippetsModel: SnippetsViewModel?
    @State private var dropError: String?

    var body: some View {
        Group {
            if let workspace = selectedWorkspace {
                WorkspaceView(workspace: workspace, sessions: sessions, store: environment.terminalViews,
                              vault: vault, terminalSettings: environment.terminalSettings,
                              sidePanel: sidePanel,
                              closeSidePanel: { sidePanel = nil },
                              changeTheme: { sidePanel = TerminalSidePanel(tabID: $0, kind: .theme) },
                              showSnippets: { sidePanel = TerminalSidePanel(tabID: $0, kind: .snippets) },
                              closePane: { environment.closeTab(tabID: $0) },
                              editHost: isTerminalWindow ? nil : { editHost(of: $0) },
                              editSnippet: isTerminalWindow ? nil : { editSnippet($0) })
                    .id(workspace.id)
            } else if let tab = selectedTab {
                TerminalTabView(tab: tab, sessions: sessions, store: environment.terminalViews,
                                vault: vault, terminalSettings: environment.terminalSettings,
                                closeTab: { environment.closeTab(tabID: tab.id) },
                                sidePanel: sidePanel?.tabID == tab.id ? sidePanel?.kind : nil,
                                closeSidePanel: { sidePanel = nil },
                                editHost: isTerminalWindow ? nil : { editHost(of: tab) },
                                editSnippet: isTerminalWindow ? nil : { editSnippet($0) })
                    // A tab dragged from the bar, or a host card, dropped on a half of the terminal
                    // turns this tab into a workspace with both.
                    // Not the tab itself: dropping it on its own terminal can't split anything.
                    .terminalDropZone(
                        isDragSource: sessions.draggedTabID == tab.id,
                        onDropTab: { droppedID, edge in dropTab(droppedID, onto: tab, at: edge) },
                        onDropHost: { hostID, edge in dropHost(hostID, onto: tab, at: edge) }
                    )
                    .id(tab.id)
            } else if isTerminalWindow {
                // Only while the window opens or closes.
                Theme.contentBackground
            } else {
                MainArea(
                    environment: environment,
                    navigation: environment.navigation,
                    vault: vault,
                    sessions: sessions,
                    terminalSettings: environment.terminalSettings,
                    hostsModel: hostsModel,
                    keychainModel: keychainModel,
                    logsModel: logsModel,
                    snippetsModel: snippetsModel
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
            if snippetsModel == nil {
                snippetsModel = SnippetsViewModel(vault: vault)
            }
        }
        .onChange(of: sessions.tabs.map(\.id)) { _, openIDs in
            // Every window's tabs: a window must not drop another window's terminal views.
            environment.terminalViews.retain(only: Set(openIDs))
            if let id = sidePanel?.tabID, !openIDs.contains(id) { sidePanel = nil }
        }
        // The panel belongs to the tab (or workspace pane) it was opened on; showing another tab bar
        // item, or the pane leaving the workspace, closes it.
        .onChange(of: shownTabIDs) { _, ids in
            if let id = sidePanel?.tabID, !ids.contains(id) { sidePanel = nil }
        }
        .alert("Couldn\u{2019}t Open the Host", isPresented: Binding(
            get: { dropError != nil },
            set: { if !$0 { dropError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dropError ?? "")
        }
        // Cmd+.: the snippets panel of this window's selected tab.
        .focusedSceneValue(\.snippetsPanelToggle, snippetsPanelToggle)
    }

    /// "Edit host" on the connection screen: Vaults → Hosts with the tab's host's Host Details open. The tab stays open. Main window only.
    private func editHost(of tab: TerminalTab) {
        guard let hostID = tab.savedHostID else { return }
        environment.navigation.sidebar = .hosts
        hostsModel?.edit(hostID: hostID)
        environment.showVaults()
    }

    // MARK: Drops on a plain tab

    /// A tab of this window dragged onto this tab's terminal: both become one workspace, the dropped
    /// one on the half it was dropped on.
    private func dropTab(_ droppedID: UUID, onto tab: TerminalTab, at edge: DropEdge) {
        guard droppedID != tab.id,
              sessions.tabs(inWindow: tab.windowID).contains(where: { $0.id == droppedID }),
              // A pane of a workspace isn't a tab of the bar; it is never pulled out of its workspace here.
              sessions.workspace(containing: droppedID) == nil else { return }
        guard let workspace = sessions.makeWorkspace(from: [tab.id, droppedID], name: nil) else { return }
        sessions.movePane(droppedID, beside: tab.id, at: edge, in: workspace.id)
        sessions.focusPane(droppedID)
        environment.show(workspace)
    }

    /// A host card dropped onto this tab's terminal: a new connection beside it, as one workspace.
    /// Main window only (new connections open there).
    private func dropHost(_ hostID: UUID, onto tab: TerminalTab, at edge: DropEdge) {
        guard tab.windowID == nil else { return }
        do {
            let added = try sessions.open(hostID: hostID)
            guard let workspace = sessions.makeWorkspace(from: [tab.id, added.id], name: nil) else { return }
            sessions.movePane(added.id, beside: tab.id, at: edge, in: workspace.id)
            sessions.focusPane(added.id)
            environment.show(workspace)
        } catch {
            dropError = error.localizedDescription
        }
    }

    /// Edit / New Snippet in the snippets panel: Vaults → Snippets. The tab stays open. Main window only.
    /// The Snippets screen has no "select this snippet" entry point yet, so `id` only names the
    /// snippet meant (wired up at merge, see the S3 report).
    private func editSnippet(_ id: UUID) {
        environment.navigation.snippetToSelect = id
        environment.navigation.sidebar = .snippets
        environment.showVaults()
    }

    /// Opens the snippets panel on the selected tab, or a workspace's focused pane (closing Change
    /// Theme), or closes it.
    private var snippetsPanelToggle: SnippetsPanelToggle {
        guard let tabID = selectedWorkspace?.focusedPaneID ?? selectedTab?.id else { return SnippetsPanelToggle() }
        let panel = TerminalSidePanel(tabID: tabID, kind: .snippets)
        let binding = $sidePanel
        return SnippetsPanelToggle(isOpen: sidePanel == panel) {
            binding.wrappedValue = binding.wrappedValue == panel ? nil : panel
        }
    }

    /// This window's selected tab; nil while Vaults is selected. In a workspace, one of its panes.
    private var selectedTab: TerminalTab? {
        guard let id = sessions.selectedTabID(inWindow: windowID) else { return nil }
        return sessions.tabs.first { $0.id == id }
    }

    /// The workspace shown in this window: the one holding the selected tab.
    private var selectedWorkspace: Workspace? {
        selectedTab.flatMap { sessions.workspace(containing: $0.id) }
    }

    /// The tabs whose terminals are shown: the workspace's panes, or the selected tab.
    private var shownTabIDs: [UUID] {
        if let workspace = selectedWorkspace { return workspace.paneIDs }
        return selectedTab.map { [$0.id] } ?? []
    }
}

private struct MainArea: View {
    /// For the Hosts screen's workspace actions (saved workspaces, Open in Workspace).
    let environment: AppEnvironment
    let navigation: AppNavigation
    let vault: LocalVault
    let sessions: SessionManager
    /// For Host Details' "Default (…)" theme label (passed on to `HostsView`).
    let terminalSettings: TerminalSettings
    let hostsModel: HostsViewModel?
    let keychainModel: KeychainViewModel?
    let logsModel: LogsViewModel?
    let snippetsModel: SnippetsViewModel?

    @Environment(\.openWindow) private var openWindow

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
                HostsView(model: hostsModel, vault: vault, sessions: sessions, terminalSettings: terminalSettings,
                          workspaceTemplates: environment.workspaceTemplates,
                          openWorkspace: { try environment.openWorkspace(hostIDs: $0) },
                          openTemplate: { try environment.openWorkspaceTemplate($0) },
                          openTemplateInNewWindow: { template in
                              openWindow(id: TerminalWindowRequest.sceneID,
                                         value: TerminalWindowRequest(templateID: template.id))
                          },
                          connectInNewWindow: { hostID in
                              // Checked here so a host that can't connect shows why instead of an empty window.
                              _ = try ConnectionPlanner.plan(hostID: hostID, vault: vault)
                              openWindow(id: TerminalWindowRequest.sceneID, value: TerminalWindowRequest(hostID: hostID))
                          })
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
        case .snippets:
            if let snippetsModel {
                SnippetsView(model: snippetsModel, vault: vault, sessions: sessions, navigation: navigation)
            } else {
                Theme.contentBackground
            }
        case .knownHosts:
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
