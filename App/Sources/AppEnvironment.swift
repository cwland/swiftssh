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
    let connectionSettings = ConnectionSettings()
    /// Per-Mac terminal preferences (Settings → Terminal).
    let terminalSettings = TerminalSettings()
    /// Per-Mac 1Password path overrides (Settings → 1Password → Advanced).
    let onePasswordSettings: OnePasswordSettings
    /// The 1Password setup status; also finds the agent socket and `op` for sessions.
    let onePassword: OnePasswordSetup
    /// Per-Mac app appearance (Settings sidebar); applied to `NSApp.appearance` live.
    let appAppearance = AppAppearanceSetting()
    /// The Settings window's selected pane ("Open 1Password Setup" selects 1Password).
    let settingsNavigation = SettingsNavigation()
    /// Set together with `.ready`.
    private(set) var sessions: SessionManager?
    /// Syncs the vault with the sync server (Settings → Sync, the Vaults tab's cloud icon).
    /// Set together with `.ready`, and started then.
    private(set) var sync: SyncCoordinator?
    /// One SwiftTerm view per open tab, so switching tabs and reconnecting keep scrollback.
    @ObservationIgnored let terminalViews = TerminalViewStore()

    @ObservationIgnored private let keyProvider: any VaultKeyProvider
    @ObservationIgnored private let syncSecrets: any SyncSecretsStore
    @ObservationIgnored private var didStartLoading = false
    @ObservationIgnored private var runtime: SSHRuntimeDirectory?

    init(keyProvider: any VaultKeyProvider = KeychainVaultKeyProvider(),
         syncSecrets: any SyncSecretsStore = KeychainSyncSecretsStore()) {
        self.keyProvider = keyProvider
        self.syncSecrets = syncSecrets
        self.navigation = AppNavigation()
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

    /// Loads the Keychain key and opens `~/Library/Application Support/TermiusReimagined/vault.bin`.
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
        BadgeLogoStore.createDirectoryIfNeeded()
        BadgeLogoStore.shared.startAutomaticDownloads() // background; never delays the vault opening
        var keyWasCreated = false
        do {
            let fileURL = try Self.vaultFileURL()
            let runtime = prepareRuntimeDirectory(
                root: fileURL.deletingLastPathComponent().appendingPathComponent("run", isDirectory: true))
            let provider = keyProvider
            // Keychain calls can block (e.g. an access prompt), so keep them off the main actor.
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> (key: VaultKey, created: Bool) in
                if let keychain = provider as? KeychainVaultKeyProvider {
                    return try keychain.loadOrCreateKeyReportingCreation()
                }
                return (try provider.loadOrCreateKey(), false)
            }.value
            keyWasCreated = loaded.created
            let persistence = EncryptedFileVaultPersistence(fileURL: fileURL, key: loaded.key)
            let vault = try await LocalVault.open(persistence: persistence)
            sessions = makeSessionManager(vault: vault, runtime: runtime)
            state = .ready(vault)
            startSync(vault: vault)
        } catch VaultLoadError.unreadable(let movedTo) {
            state = .failed(.unreadable(movedTo: movedTo.path, keyWasCreated: keyWasCreated))
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

    // MARK: Sessions

    /// Empties `~/Library/Application Support/TermiusReimagined/run` (left-over temporary files of
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
            keepAlivePolicy: { connectionSettings.detection.policy },
            autoReconnectEnabled: { connectionSettings.autoReconnect },
            // Looked up at each connect, so a socket or `op` that appears later (or a changed
            // override) is used without restarting the app.
            agentSocket: { onePassword.agentSocket() },
            opClient: { onePassword.makeClient() },
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
    func selectedTab(in scope: WindowScope?) -> TerminalTab? {
        guard let scope, let sessions, let id = sessions.selectedTabID(inWindow: scope.windowID) else { return nil }
        return sessions.tabs.first { $0.id == id }
    }

    /// Closes the tab at once, connected or not (no confirmation).
    func closeTab(tabID: UUID) {
        sessions?.close(tabID: tabID)
        releaseClosedTerminalViews()
    }

    /// Lets go of closed tabs' terminal views (and scrollback) now, even when no window is showing
    /// tabs. Open tabs keep theirs, including the main tabs while no main window is open.
    private func releaseClosedTerminalViews() {
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

    /// Cmd+W: closes the focused window's selected terminal tab; with Vaults selected (or another kind of
    /// window, such as Settings, focused), closes the window.
    func closeSelectedTabOrWindow(in scope: WindowScope?) {
        if let tab = selectedTab(in: commandScope(scope)) {
            closeTab(tabID: tab.id)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// Cmd+1 shows Vaults (main window only); Cmd+2…9 select the focused window's first eight
    /// terminal tabs, in tab bar order.
    func selectTab(number: Int, in scope: WindowScope?) {
        let scope = commandScope(scope)
        guard let sessions else { return }
        if number == 1 {
            if !scope.isTerminalWindow { showVaults() }
            return
        }
        let windowTabs = sessions.tabs(inWindow: scope.windowID)
        guard windowTabs.indices.contains(number - 2) else { return }
        sessions.select(tabID: windowTabs[number - 2].id, inWindow: scope.windowID)
    }

    /// Cmd+Shift+[ / Cmd+Shift+]: the focused window's previous or next tab, in tab bar order.
    func selectAdjacentTab(by step: Int, in scope: WindowScope?) {
        let scope = commandScope(scope)
        guard let sessions else { return }
        if step < 0 {
            sessions.selectPreviousTab(inWindow: scope.windowID)
        } else {
            sessions.selectNextTab(inWindow: scope.windowID)
        }
    }

    /// Shows Vaults in the main window.
    func showVaults() {
        sessions?.selectedTabID = nil
        navigation.selectedTab = .vaults
    }

    /// Cmd+R: reconnects the focused window's selected tab while its disconnected banner shows.
    func reconnectSelectedTab(in scope: WindowScope?) {
        guard let sessions, let tab = selectedTab(in: commandScope(scope)), case .disconnected = tab.state else { return }
        sessions.reconnect(tabID: tab.id)
    }

    // MARK: Windows

    /// The scope of every open window that shows a `RootView`, by window (see `commandScope`).
    @ObservationIgnored private var windowScopes: [ObjectIdentifier: WindowScope] = [:]

    func windowAttached(_ window: NSWindow, scope: WindowScope) {
        windowScopes[ObjectIdentifier(window)] = scope
    }

    /// A window closed. Main windows (the launch window, Cmd+N ones) leave the main tabs running, as in
    /// v0.6.0: they come back when a main window opens again. A terminal window ("Duplicate in New
    /// Window") ends its own sessions, without asking (as closing a tab does).
    func windowClosed(_ window: NSWindow, scope: WindowScope) {
        windowScopes[ObjectIdentifier(window)] = nil
        guard let windowID = scope.windowID else { return }
        sessions?.closeWindow(windowID)
        releaseClosedTerminalViews()
    }

    // MARK: Files

    /// `~/Library/Application Support/TermiusReimagined`; created if needed.
    static func supportDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("TermiusReimagined", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `~/Library/Application Support/TermiusReimagined/vault.bin`; creates the folder if needed.
    static func vaultFileURL() throws -> URL {
        try supportDirectoryURL().appendingPathComponent("vault.bin", isDirectory: false)
    }
}
