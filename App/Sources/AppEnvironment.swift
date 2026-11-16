import Foundation
import Observation
import SystemConfiguration
import AppKit
import AppCore
import SyncCore
import SSHCore

/// App-wide state: navigation, the local vault (opened once at launch) and the terminal sessions.
@MainActor @Observable
final class AppEnvironment {
    enum State {
        case loading
        case ready(LocalVault)
        case failed(LoadFailure)
    }

    enum LoadFailure {
        /// The vault file couldn't be decrypted and was moved aside to `movedTo`. Loading again
        /// starts with a new, empty vault.
        case unreadable(movedTo: String, keyWasCreated: Bool)
        case other(String)
    }

    private(set) var state: State = .loading
    let navigation: AppNavigation
    /// Per-Mac connection preferences (Settings → Connection); read when a session is opened.
    let connectionSettings: ConnectionSettings
    /// Network changes and wake from sleep make every session check its server at once.
    private var connectionWatcher: ConnectionWatcher?
    /// Per-Mac terminal preferences (Settings → Terminal).
    let terminalSettings: TerminalSettings
    /// Per-Mac 1Password path overrides (Settings → 1Password → Advanced).
    let onePasswordSettings: OnePasswordSettings
    /// The 1Password setup status; also finds the agent socket and `op` for sessions.
    let onePassword: OnePasswordSetup
    /// Per-Mac app appearance (Settings sidebar); applied to `NSApp.appearance` live.
    let appAppearance: AppAppearanceSetting
    /// The Settings window's selected pane ("Open 1Password Setup" selects 1Password).
    let settingsNavigation = SettingsNavigation()
    /// The welcome sheet's "Don't show again" (per Mac).
    let welcomeSettings = WelcomeSettings()
    /// Whether the main window shows the welcome sheet (first launch, or Help → Set Up SwiftSSH…).
    var isShowingWelcome = false
    /// Set together with `.ready`.
    private(set) var sessions: SessionManager?
    /// Syncs the vault with the sync server (Settings → Sync, the Vaults tab's cloud icon).
    /// Set together with `.ready`, and started then.
    private(set) var sync: SyncCoordinator?
    /// One SwiftTerm view per open tab, so switching tabs and reconnecting keep scrollback.
    @ObservationIgnored let terminalViews = TerminalViewStore()
    /// Saved workspaces (templates), on this Mac only (never synced): `workspaces.json` next to the vault.
    let workspaceTemplates = WorkspaceTemplateStore(fileURL: AppEnvironment.workspacesFileURL)

    @ObservationIgnored private let keyProvider: any VaultKeyProvider
    @ObservationIgnored private let syncSecrets: any SyncSecretsStore
    @ObservationIgnored private var didStartLoading = false
    @ObservationIgnored private var didOfferWelcome = false
    @ObservationIgnored private var runtime: SSHRuntimeDirectory?

    init(keyProvider: any VaultKeyProvider = KeychainVaultKeyProvider(),
         syncSecrets: any SyncSecretsStore = KeychainSyncSecretsStore()) {
        self.keyProvider = keyProvider
        self.syncSecrets = syncSecrets
        self.navigation = AppNavigation()
        // Before any settings object reads UserDefaults: bring over Termius Reimagined's settings.
        AppEnvironment.migrateSettingsFromTermiusReimagined()
        self.connectionSettings = ConnectionSettings()
        self.terminalSettings = TerminalSettings()
        self.appAppearance = AppAppearanceSetting()
        let onePasswordSettings = OnePasswordSettings()
        self.onePasswordSettings = onePasswordSettings
        self.onePassword = OnePasswordSetup(settings: onePasswordSettings)
        appAppearance.onChange = { Self.applyAppearance($0) }
        Self.applyAppearance(appAppearance.appearance)
    }

    /// nil follows macOS. `NSApp` can still be nil this early in launch; `load()` applies it again.
    private static func applyAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Loads the Keychain key and opens `~/Library/Application Support/SwiftSSH/vault.bin`, after
    /// the one-time move from Termius Reimagined (`RebrandMigration`) on the first launch.
    /// Runs once per launch; a failed load is only tried again through `retry()`.
    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        Self.applyAppearance(appAppearance.appearance)
        await openVault()
    }

    /// Tries again after a failed load (the user's button on the failure screen).
    func retry() async {
        guard case .failed = state else { return }
        await openVault()
    }

    private func openVault() async {
        state = .loading
        // When this process is the host app for unit tests, don't touch the real Keychain item
        // or vault file: an ad-hoc signed rebuild would raise a Keychain prompt on every test
        // run, and tests must never create or move aside the user's vault. Stay `.loading`.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        var keyWasCreated = false
        do {
            let fileURL = try Self.vaultFileURL()
            let provider = keyProvider
            // Keychain calls can block (e.g. an access prompt), so keep them off the main actor.
            // The migration runs first and the key is loaded only once it succeeded: a fresh key
            // must never be created while a Termius Reimagined vault is still waiting to be copied.
            let loaded = try await Task.detached(priority: .userInitiated) {
                try AppEnvironment.migrateAndLoadKey(provider: provider)
            }.value
            if loaded.filesCopied {
                // Read before the copy (at init): read them again.
                workspaceTemplates.reload()
                BadgeLogoStore.shared.reload()
            }
            BadgeLogoStore.createDirectoryIfNeeded()
            BadgeLogoStore.shared.startAutomaticDownloads() // background; never delays the vault opening
            let runtime = prepareRuntimeDirectory(
                root: fileURL.deletingLastPathComponent().appendingPathComponent("run", isDirectory: true))
            keyWasCreated = loaded.created
            let persistence = EncryptedFileVaultPersistence(fileURL: fileURL, key: loaded.key)
            let vault = try await LocalVault.open(persistence: persistence)
            // Custom highlighting rules live in the vault; open terminals pick them up at once.
            TerminalHighlighting.rules.attach(vault)
            let sessions = makeSessionManager(vault: vault, runtime: runtime)
            self.sessions = sessions
            workspaceTemplates.attach(sessions)
            let watcher = ConnectionWatcher { [weak sessions] in sessions?.checkConnections() }
            watcher.start()
            connectionWatcher = watcher
            OnePasswordApp.watchAgentSigning(sessions, focus: onePassword.promptFocus)
            onePassword.pinnedKeys = { [weak vault] in vault.map { PinnedAgentKey.all(in: $0) } ?? [] }
            state = .ready(vault)
            startSync(vault: vault)
            offerWelcomeIfNew(vault: vault)
        } catch VaultLoadError.unreadable(let movedTo) {
            state = .failed(.unreadable(movedTo: movedTo.path, keyWasCreated: keyWasCreated))
        } catch let error as RebrandMigrationError {
            // Nothing was created or moved aside; Try Again runs the migration again.
            state = .failed(.other(error.errorDescription ?? "SwiftSSH couldn\u{2019}t move your Termius Reimagined vault over."))
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            state = .failed(.other("The vault could not be opened: \(detail)"))
        }
    }

    /// The open vault, nil until `.ready`.
    var vault: LocalVault? {
        if case .ready(let vault) = state { return vault }
        return nil
    }

    // MARK: Sync

    /// Creates the one `SyncCoordinator` for the open vault and starts it: with a server and a
    /// vault key on this Mac it syncs now and then on its timer; otherwise it waits in Settings → Sync.
    private func startSync(vault: LocalVault) {
        guard sync == nil else { return }
        let coordinator = SyncCoordinator(vault: vault, secrets: syncSecrets)
        sync = coordinator
        coordinator.start()
    }

    /// Stops the sync loop (app quit), before the final vault write.
    func stopSync() {
        sync?.stop()
    }

    // MARK: Welcome

    /// Opens the welcome sheet once per launch on a Mac that looks new (`WelcomeSetup.shouldShowAtLaunch`):
    /// an empty vault and no sync server. Never for a Mac with data or sync set up.
    private func offerWelcomeIfNew(vault: LocalVault) {
        guard !didOfferWelcome else { return }
        didOfferWelcome = true
        let syncConfigured = sync?.serverURL != nil
        if WelcomeSetup.shouldShowAtLaunch(liveCounts: vault.liveCounts(), syncServerConfigured: syncConfigured,
                                           settings: welcomeSettings) {
            isShowingWelcome = true
        }
    }

    /// Help → Set Up SwiftSSH…: shows the welcome sheet in the main window (once the vault is open).
    func showWelcome() {
        guard vault != nil else { return }
        isShowingWelcome = true
    }

    // MARK: Sessions

    /// Empties `~/Library/Application Support/SwiftSSH/run` (left-over temporary files of
    /// an earlier run) and recreates the askpass helper, once per launch.
    private func prepareRuntimeDirectory(root: URL) -> SSHRuntimeDirectory {
        if let runtime { return runtime }
        let directory = SSHRuntimeDirectory(root: root)
        do {
            try directory.clean()
            try directory.prepare()
        } catch {
            // System ssh sessions prepare the directory again before use and report a failure then.
            NSLog("Could not prepare the SSH runtime directory: %@", error.localizedDescription)
        }
        runtime = directory
        return directory
    }

    private func makeSessionManager(vault: LocalVault, runtime: SSHRuntimeDirectory) -> SessionManager {
        let knownHosts = KnownHostsStore(vault: vault)
        let connectionSettings = self.connectionSettings
        let terminalSettings = self.terminalSettings
        let onePassword = self.onePassword
        return SessionManager(
            vault: vault,
            knownHosts: knownHosts,
            makeSession: { plan, evaluator in
                switch plan.engine {
                case .citadel:
                    return CitadelSession(plan: plan, hostKeys: evaluator)
                case .systemSSH:
                    return SystemSSHSession(plan: plan, hostKeys: evaluator,
                                            knownHostsLines: { await knownHosts.knownHostsFileLines() },
                                            runtime: runtime)
                }
            },
            deviceName: Self.deviceName,
            defaultUsername: NSUserName(),
            keepAlivePolicy: { connectionSettings.keepAlivePolicy },
            autoReconnectEnabled: { connectionSettings.autoReconnect },
            // Looked up at each connect, so a socket or `op` that appears later (or a changed
            // override) is used without restarting the app.
            agentSocket: { onePassword.agentSocket() },
            opClient: { onePassword.makeClient() },
            // After a rejected 1Password key: what the agent offers decides the message.
            agentKeys: { try await SSHAgentClient.listKeys(socketPath: $0) },
            terminalType: { terminalSettings.terminalType }
        )
    }

    /// The Mac's name as set in System Settings (e.g. "Cory's Mac mini"), for connection logs.
    private static var deviceName: String {
        SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String } ?? ProcessInfo.processInfo.hostName
    }

    /// The main window's selected terminal tab, nil while Vaults is selected.
    var selectedTab: TerminalTab? {
        selectedTab(in: WindowScope(windowID: nil))
    }

    /// The selected tab of the window (`scope` from the focused scene); nil for Vaults or no window.
    /// While a workspace is shown this is one of its panes; `activeTab(in:)` is its focused pane.
    func selectedTab(in scope: WindowScope?) -> TerminalTab? {
        guard let scope, let sessions, let id = sessions.selectedTabID(inWindow: scope.windowID) else { return nil }
        return sessions.tabs.first { $0.id == id }
    }

    /// The workspace shown in the window (its selected tab is one of the workspace's panes); nil for a
    /// plain tab or Vaults.
    func selectedWorkspace(in scope: WindowScope?) -> Workspace? {
        guard let sessions, let tab = selectedTab(in: scope) else { return nil }
        return sessions.workspace(containing: tab.id)
    }

    /// The tab commands act on: the focused pane of the shown workspace, else the selected tab.
    func activeTab(in scope: WindowScope?) -> TerminalTab? {
        guard let sessions else { return nil }
        if let workspace = selectedWorkspace(in: scope) {
            return sessions.tabs.first { $0.id == workspace.focusedPaneID }
        }
        return selectedTab(in: scope)
    }

    /// Closes the tab at once, connected or not (no confirmation). A workspace pane closes as a pane
    /// (the workspace turns back into a plain tab when one is left). When that pane is the one before
    /// the last, the workspace has unsaved changes and "Ask to save workspaces when closing" is on, its
    /// window's tab bar first asks Save / Don't Save / Cancel (`closingPaneRequest`, taken by one window
    /// only: the key window when it shows the workspace, else the frontmost one that does); the pane closes
    /// after Save or Don't Save (`closeTabWithoutAsking`). If no tab bar takes the request soon
    /// (no window shows that workspace), the pane closes without asking, so a stale request never
    /// blocks closing it again or pops up later in a window that opens.
    func closeTab(tabID: UUID) {
        guard let sessions else { return }
        if let workspace = sessions.workspaceToSaveBeforeClosing(pane: tabID,
                                                                 asksToSave: connectionSettings.askToSaveWorkspaces) {
            closingPaneRequestCount += 1
            let request = closingPaneRequestCount
            closingPaneRequest = WindowTargetedRequest(subjectID: tabID,
                                                       window: promptWindow(showingWindowID: workspace.windowID))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.closingPaneRequestTimeout)
                guard let self, self.closingPaneRequestCount == request,
                      self.closingPaneRequest?.subjectID == tabID else { return }
                self.closingPaneRequest = nil
                self.closeTabWithoutAsking(tabID: tabID)
            }
            return
        }
        closeTabWithoutAsking(tabID: tabID)
    }

    /// A pane waiting for the tab bar's Save / Don't Save / Cancel before it closes (see `closeTab`), and
    /// the window (`ObjectIdentifier` of its `NSWindow`) whose tab bar asks.
    var closingPaneRequest: WindowTargetedRequest<ObjectIdentifier>?
    /// Tells a request apart from a later one for the same pane (see `closeTab`).
    @ObservationIgnored private var closingPaneRequestCount = 0
    /// How long a tab bar has to take a `closingPaneRequest` before the pane closes without asking.
    private static let closingPaneRequestTimeout: Duration = .milliseconds(300)

    /// Closes the tab or pane at once, never asking.
    func closeTabWithoutAsking(tabID: UUID) {
        guard let sessions else { return }
        if let workspace = sessions.workspace(containing: tabID) {
            closePane(tabID, of: workspace)
        } else {
            sessions.close(tabID: tabID)
            releaseClosedTerminalViews()
        }
    }

    /// Closes a pane; when it was the window's selected tab, the workspace's focused pane (or, after the
    /// workspace dissolved, the tab left over) is selected, so the window stays on it.
    private func closePane(_ paneID: UUID, of workspace: Workspace) {
        guard let sessions, let tab = sessions.tabs.first(where: { $0.id == paneID }) else { return }
        let windowID = tab.windowID
        let wasSelected = sessions.selectedTabID(inWindow: windowID) == paneID
        let workspaceID = workspace.id
        let others = workspace.paneIDs.filter { $0 != paneID }
        sessions.closePane(paneID)
        if wasSelected {
            if let remaining = sessions.workspace(workspaceID) {
                sessions.select(tabID: remaining.focusedPaneID, inWindow: windowID)
            } else if let left = others.first(where: { id in sessions.tabs.contains { $0.id == id } }) {
                sessions.select(tabID: left, inWindow: windowID)
            }
        }
        releaseClosedTerminalViews()
    }

    /// Close Workspace: ends all its sessions.
    func closeWorkspace(_ id: UUID) {
        sessions?.closeWorkspace(id)
        releaseClosedTerminalViews()
    }

    /// Shows the workspace in its window (selects its focused pane).
    func show(_ workspace: Workspace) {
        guard let sessions, let pane = sessions.tabs.first(where: { $0.id == workspace.focusedPaneID }) else { return }
        sessions.select(tabID: pane.id, inWindow: pane.windowID)
    }

    /// Lets go of closed tabs' terminal views (and scrollback) now, even when no window is showing
    /// tabs. Open tabs keep theirs, including the main tabs while no main window is open.
    func releaseClosedTerminalViews() {
        terminalViews.retain(only: Set(sessions?.tabs.map(\.id) ?? []))
    }

    /// The window commands act on: the focused scene's, else the key window's (a window that showed a
    /// `RootView`), else the main window's tabs. So a nil focused value never turns a Cmd+W meant for
    /// a tab into closing a window (with Settings key, Cmd+W acts on the main tabs, as in v0.6.0).
    func commandScope(_ focused: WindowScope?) -> WindowScope {
        if let focused { return focused }
        if let key = NSApp.keyWindow, let scope = windowScopes[ObjectIdentifier(key)] { return scope }
        return WindowScope(windowID: nil)
    }

    /// Cmd+W: closes the focused window's selected terminal tab; in a workspace, its focused pane (the
    /// last two follow the dissolve rule: one left = a plain tab). With Vaults selected, closes the window.
    /// With Settings (or any other window without tabs) key, that window closes (standard close), never a
    /// tab of a window behind it (`WindowRouting.closeCommand`).
    func closeSelectedTabOrWindow(in scope: WindowScope?) {
        let keyWindow = NSApp.keyWindow
        // A sheet or a popover counts as the window it belongs to.
        let kind: WindowRouting.KeyWindow? = keyWindow.map { window in
            var owner = window
            while let parent = owner.sheetParent ?? owner.parent { owner = parent }
            return windowScopes[ObjectIdentifier(owner)] == nil ? WindowRouting.KeyWindow.otherWindow : .appWindow
        }
        // The focused scene's scope is ignored when another kind of window is key.
        let tab = kind == .otherWindow ? nil : activeTab(in: commandScope(scope))
        switch WindowRouting.closeCommand(keyWindow: kind, hasActiveTab: tab != nil) {
        case .closeTabOrPane:
            if let tab { closeTab(tabID: tab.id) }
        case .closeKeyWindow:
            keyWindow?.performClose(nil)
        }
    }

    /// Cmd+1 shows Vaults (main window only); Cmd+2…9 select the focused window's first eight
    /// tab bar items (plain tabs and workspaces), in tab bar order.
    func selectTab(number: Int, in scope: WindowScope?) {
        let scope = commandScope(scope)
        guard let sessions else { return }
        if number == 1 {
            if !scope.isTerminalWindow { showVaults() }
            return
        }
        let strip = sessions.strip(inWindow: scope.windowID)
        guard strip.indices.contains(number - 2) else { return }
        select(strip[number - 2], inWindow: scope.windowID)
    }

    /// Cmd+Shift+[ / Cmd+Shift+]: the focused window's previous or next tab bar item (a workspace counts
    /// as one), wrapping; from Vaults, the first or last.
    func selectAdjacentTab(by step: Int, in scope: WindowScope?) {
        let scope = commandScope(scope)
        guard let sessions else { return }
        let strip = sessions.strip(inWindow: scope.windowID)
        guard !strip.isEmpty else { return }
        let next: Int
        if let current = selectedStripItem(in: scope), let index = strip.firstIndex(of: current) {
            next = (index + (step < 0 ? -1 : 1) + strip.count) % strip.count
        } else {
            next = step < 0 ? strip.count - 1 : 0
        }
        select(strip[next], inWindow: scope.windowID)
    }

    /// The tab bar item shown in the window: the workspace holding the selected tab, or that tab.
    func selectedStripItem(in scope: WindowScope?) -> StripItem? {
        guard let tab = selectedTab(in: scope) else { return nil }
        if let workspace = sessions?.workspace(containing: tab.id) { return .workspace(workspace.id) }
        return .tab(tab.id)
    }

    /// Shows a tab bar item: a plain tab, or a workspace (its focused pane is selected).
    func select(_ item: StripItem, inWindow windowID: UUID?) {
        guard let sessions else { return }
        switch item {
        case .tab(let id):
            sessions.select(tabID: id, inWindow: windowID)
        case .workspace(let id):
            guard let workspace = sessions.workspace(id) else { return }
            sessions.select(tabID: workspace.focusedPaneID, inWindow: windowID)
        }
    }

    // MARK: Workspaces

    /// Cmd+B: broadcast input on or off in the shown workspace.
    func toggleBroadcast(in scope: WindowScope?) {
        guard let workspace = selectedWorkspace(in: commandScope(scope)) else { return }
        sessions?.toggleBroadcast(in: workspace.id)
    }

    /// Cmd+Shift+M: Split view ↔ Focus mode in the shown workspace.
    func toggleViewMode(in scope: WindowScope?) {
        guard let workspace = selectedWorkspace(in: commandScope(scope)) else { return }
        sessions?.setViewMode(workspace.viewMode == .split ? .focus : .split, for: workspace.id)
    }

    /// Cmd+S on a never-saved workspace: its window's tab bar asks for the name, then saves. Only the
    /// window named in the request asks (two main windows show the same workspace).
    var namingWorkspaceRequest: WindowTargetedRequest<ObjectIdentifier>?

    /// Cmd+S: saves the shown workspace to its template; the first time, asks for its name first.
    func saveSelectedWorkspace(in scope: WindowScope?) throws {
        guard let workspace = selectedWorkspace(in: commandScope(scope)) else { return }
        guard workspaceTemplates.hasSavedCopy(of: workspace) else {
            namingWorkspaceRequest = WindowTargetedRequest(subjectID: workspace.id,
                                                           window: promptWindow(showingWindowID: workspace.windowID))
            return
        }
        try saveWorkspace(workspace)
    }

    /// Save Workspace (⌘S, the tab's grey dot, its menu): name, panes' hosts, titles, layout, view mode.
    @discardableResult
    func saveWorkspace(_ workspace: Workspace) throws -> WorkspaceTemplate? {
        guard let sessions else { return nil }
        return try workspaceTemplates.save(workspace, sessions: sessions)
    }

    /// Renames an open workspace and its saved copy, if it has one.
    func renameWorkspace(_ workspace: Workspace, to name: String) throws {
        guard let sessions else { return }
        try workspaceTemplates.rename(workspace, to: name, sessions: sessions)
    }

    /// Opens a saved workspace (each pane connects) in the main window and shows it.
    func openWorkspaceTemplate(_ template: WorkspaceTemplate) throws {
        guard let sessions else { return }
        let workspace = try sessions.openTemplate(template)
        show(workspace)
    }

    /// Open in Workspace (Hosts screen): a new connection per host, as one workspace, shown.
    func openWorkspace(hostIDs: [UUID]) throws {
        guard let sessions else { return }
        let workspace = try sessions.openWorkspace(hostIDs: hostIDs, name: nil)
        show(workspace)
    }

    /// Split Right / Split Down on a plain tab: it becomes a workspace with a duplicate connection
    /// beside it, which gets the focus.
    func splitTab(_ tabID: UUID, at edge: DropEdge) throws {
        guard let sessions else { return }
        let before = Set(sessions.tabs.map(\.id))
        let workspace = try sessions.splitTab(tabID, at: edge)
        if let added = workspace.paneIDs.first(where: { !before.contains($0) }) {
            sessions.focusPane(added)
        }
        show(workspace)
    }

    /// Shows Vaults in the main window.
    func showVaults() {
        sessions?.selectedTabID = nil
        navigation.selectedTab = .vaults
    }

    /// Cmd+R: reconnects the focused window's selected tab (a workspace's focused pane) while its
    /// disconnected banner shows.
    func reconnectSelectedTab(in scope: WindowScope?) {
        guard let sessions, let tab = activeTab(in: commandScope(scope)), case .disconnected = tab.state else { return }
        sessions.reconnect(tabID: tab.id)
    }

    /// Shows an error from a menu command (no view to hold an alert): a sheet on the key window.
    func presentCommandError(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Windows

    /// The scope of every open window that shows a `RootView`, by window (see `commandScope`).
    @ObservationIgnored private var windowScopes: [ObjectIdentifier: WindowScope] = [:]

    /// The one window that shows a prompt about tabs of `windowID` (nil = the main tabs): the key window
    /// when it shows them, else the frontmost window that does, else the key window.
    func promptWindow(showingWindowID windowID: UUID?) -> ObjectIdentifier? {
        let showing = NSApp.orderedWindows.compactMap { window -> ObjectIdentifier? in
            // A hidden or minimized window can't show the prompt: nobody would see it.
            guard window.isVisible, !window.isMiniaturized else { return nil }
            let id = ObjectIdentifier(window)
            guard let scope = windowScopes[id], scope.windowID == windowID else { return nil }
            return id
        }
        return WindowRouting.promptWindow(among: showing, keyWindow: NSApp.keyWindow.map { ObjectIdentifier($0) })
    }

    func windowAttached(_ window: NSWindow, scope: WindowScope) {
        windowScopes[ObjectIdentifier(window)] = scope
    }

    /// A window closed. Main windows (the launch window, Cmd+N ones) leave the main tabs running, as in
    /// v0.6.0: they come back when a main window opens again. A terminal window ("Duplicate in New
    /// Window") ends its own sessions, without asking (as closing a tab does).
    func windowClosed(_ window: NSWindow, scope: WindowScope) {
        let closedID = ObjectIdentifier(window)
        windowScopes[closedID] = nil
        // A window address can be reused: drop requests aimed at the window that just closed.
        if namingWorkspaceRequest?.window == closedID { namingWorkspaceRequest = nil }
        guard let windowID = scope.windowID else { return }
        sessions?.closeWindow(windowID)
        releaseClosedTerminalViews()
    }

    // MARK: Migration from Termius Reimagined

    /// Runs the rebrand migration, then loads (or creates) the vault key. The key is loaded only once
    /// the migration succeeded: a fresh key must never be created while a Termius Reimagined vault is
    /// still waiting to be copied. Blocking Keychain calls: call it off the main actor.
    nonisolated fileprivate static func migrateAndLoadKey(provider: any VaultKeyProvider) throws -> LoadedVaultKey {
        let migration = makeRebrandMigration()
        let result = try migration.migrateThenLoadKey { () throws -> (key: VaultKey, created: Bool) in
            if let keychain = provider as? KeychainVaultKeyProvider {
                return try keychain.loadOrCreateKeyReportingCreation()
            }
            return (try provider.loadOrCreateKey(), false)
        }
        return LoadedVaultKey(key: result.value.key, created: result.value.created,
                              filesCopied: result.report?.filesCopied == true)
    }

    /// The one-time move from the app's former name. Built where it runs (off the main actor for
    /// the vault part); every part is real system access, so unit-test hosts never run it.
    nonisolated private static func makeRebrandMigration() -> RebrandMigration {
        let support = applicationSupportURL
        var names = RebrandMigration.Names.standard
        names.newVaultKeyService = KeychainVaultKeyProvider().service
        names.vaultKeyAccount = KeychainVaultKeyProvider().account
        names.newSyncService = KeychainSyncSecretsStore.defaultService
        names.newDefaultsDomain = Bundle.main.bundleIdentifier ?? names.newDefaultsDomain
        return RebrandMigration(
            oldDirectory: support.appendingPathComponent(RebrandMigration.oldFolderName, isDirectory: true),
            newDirectory: support.appendingPathComponent(supportFolderName, isDirectory: true),
            keychain: KeychainRebrandMigrationStore(),
            defaults: UserDefaults.standard,
            names: names,
            log: { NSLog("%@", $0) }
        )
    }

    /// Copies Termius Reimagined's settings (keys not set yet) until the migration is done. The
    /// app isn't sandboxed, so the old app's preferences domain is readable.
    private static func migrateSettingsFromTermiusReimagined() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        makeRebrandMigration().migrateSettingsIfNeeded()
    }

    // MARK: Files

    /// The app's folder name in Application Support.
    nonisolated static let supportFolderName = "SwiftSSH"

    /// `~/Library/Application Support` (falls back to the usual path if the system doesn't say).
    nonisolated private static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// `~/Library/Application Support/SwiftSSH`; created if needed.
    static func supportDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent(supportFolderName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `~/Library/Application Support/SwiftSSH/workspaces.json`: saved workspaces, this Mac
    /// only. The folder is created when the vault opens (before anything can be saved).
    static var workspacesFileURL: URL {
        applicationSupportURL
            .appendingPathComponent(supportFolderName, isDirectory: true)
            .appendingPathComponent("workspaces.json", isDirectory: false)
    }

    /// `~/Library/Application Support/SwiftSSH/vault.bin`; creates the folder if needed.
    static func vaultFileURL() throws -> URL {
        try supportDirectoryURL().appendingPathComponent("vault.bin", isDirectory: false)
    }
}

/// The vault key, and whether the rebrand migration copied files in, as loaded off the main actor
/// (`AppEnvironment.migrateAndLoadKey`).
private struct LoadedVaultKey: Sendable {
    let key: VaultKey
    let created: Bool
    let filesCopied: Bool
}
