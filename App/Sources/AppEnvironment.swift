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
    /// Per-Mac 1Password path overrides (Settings → 1Password → Advanced).
    let onePasswordSettings: OnePasswordSettings
    /// The 1Password setup status; also finds the agent socket and `op` for sessions.
    let onePassword: OnePasswordSetup
    /// The Settings window's selected pane ("Open 1Password Setup" selects 1Password).
    let settingsNavigation = SettingsNavigation()
    /// Set together with `.ready`.
    private(set) var sessions: SessionManager?
    /// One SwiftTerm view per open tab, so switching tabs and reconnecting keep scrollback.
    @ObservationIgnored let terminalViews = TerminalViewStore()

    @ObservationIgnored private let keyProvider: any VaultKeyProvider
    @ObservationIgnored private var didStartLoading = false
    @ObservationIgnored private var runtime: SSHRuntimeDirectory?

    init(keyProvider: any VaultKeyProvider = KeychainVaultKeyProvider()) {
        self.keyProvider = keyProvider
        self.navigation = AppNavigation()
        let onePasswordSettings = OnePasswordSettings()
        self.onePasswordSettings = onePasswordSettings
        self.onePassword = OnePasswordSetup(settings: onePasswordSettings)
    }

    /// Loads the Keychain key and opens `~/Library/Application Support/TermiusReimagined/vault.bin`.
    /// Runs once per launch; a failed load is only tried again through `retry()`.
    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true
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
        } catch VaultLoadError.unreadable(let movedTo) {
            state = .failed(.unreadable(movedTo: movedTo.path, keyWasCreated: keyWasCreated))
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            state = .failed(.other("The vault could not be opened: \(detail)"))
        }
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
            opClient: { onePassword.makeClient() }
        )
    }

    /// The Mac's name as set in System Settings (e.g. "Cory's Mac mini"), for connection logs.
    private static var deviceName: String {
        SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String } ?? ProcessInfo.processInfo.hostName
    }

    /// The selected terminal tab, nil while Vaults is selected.
    var selectedTab: TerminalTab? {
        guard let sessions, let id = sessions.selectedTabID else { return nil }
        return sessions.tabs.first { $0.id == id }
    }

    /// Closes the tab at once, connected or not (no confirmation).
    func closeTab(tabID: UUID) {
        sessions?.close(tabID: tabID)
    }

    /// Cmd+W: closes the selected terminal tab; with Vaults selected, closes the window.
    func closeSelectedTabOrWindow() {
        if let tab = selectedTab {
            closeTab(tabID: tab.id)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// Cmd+1 shows Vaults; Cmd+2…9 select the first eight terminal tabs.
    func selectTab(number: Int) {
        if number == 1 {
            showVaults()
            return
        }
        guard let sessions, sessions.tabs.indices.contains(number - 2) else { return }
        sessions.selectedTabID = sessions.tabs[number - 2].id
    }

    func showVaults() {
        sessions?.selectedTabID = nil
        navigation.selectedTab = .vaults
    }

    /// Cmd+R: reconnects the selected tab while its disconnected banner shows.
    func reconnectSelectedTab() {
        guard let sessions, let tab = selectedTab, case .disconnected = tab.state else { return }
        sessions.reconnect(tabID: tab.id)
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
