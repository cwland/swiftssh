import Foundation
import Observation
import UIKit
import AppCore
import SSHCore
import SyncCore

/// App-wide state of SwiftSSH for iPhone and iPad: the local vault (a synced copy of the Mac's,
/// opened once at launch), sync, the terminal sessions, the imported keys and the app lock.
///
/// Connect-only: nothing here edits hosts. Sessions never rewrite a synced host
/// (`recordsHostUpdates: false`) and plan connections the iOS way (built-in engine, imported keys).
@MainActor @Observable
final class IOSEnvironment {
    enum State {
        case loading
        case ready(LocalVault)
        case failed(String)
    }

    private(set) var state: State = .loading
    /// Set together with `.ready`.
    private(set) var sessions: SessionManager?
    /// Set together with `.ready`, and started then.
    private(set) var sync: SyncCoordinator?
    /// The first-launch join form; set together with `.ready`.
    private(set) var join: CompanionJoin?
    /// Set together with `.ready`.
    private(set) var knownHosts: KnownHostsStore?
    /// Set together with `.ready`: the Hosts screen's state (search, the open group), kept while
    /// sessions are shown.
    private(set) var hosts: HostsViewModel?
    let importedKeys: ImportedKeyLibrary
    let keyStorage: KeychainImportedKeyStorage
    let appLock: AppLock
    /// The section shown and requests from keyboard shortcuts.
    let navigation = CompanionNavigation()
    /// Default terminal theme and text size, on this device only (UserDefaults).
    let terminalSettings = TerminalSettings()
    /// Why the last host couldn't be opened; the root view shows it.
    var connectProblem: ConnectProblem?
    /// A snippet chosen on the Snippets screen for a session, waiting for its placeholder values.
    var snippetToFill: SnippetRequest?
    /// One terminal view per open session, kept while it is open.
    @ObservationIgnored let terminalViews = TerminalViewStore()

    @ObservationIgnored private let keyProvider: any VaultKeyProvider
    @ObservationIgnored private let syncSecrets: any SyncSecretsStore
    @ObservationIgnored private var didStartLoading = false

    init(keyProvider: any VaultKeyProvider = KeychainVaultKeyProvider(service: "com.cwland.SwiftSSH.mobile",
                                                                       thisDeviceOnly: true),
         syncSecrets: any SyncSecretsStore = KeychainSyncSecretsStore(service: "com.cwland.SwiftSSH.mobile.sync"),
         keyStorage: KeychainImportedKeyStorage = KeychainImportedKeyStorage()) {
        self.keyProvider = keyProvider
        self.syncSecrets = syncSecrets
        self.keyStorage = keyStorage
        self.importedKeys = ImportedKeyLibrary(storage: keyStorage)
        self.appLock = AppLock(authenticate: { await DeviceAuthenticator.authenticate(reason: "Unlock SwiftSSH") })
    }

    /// The open vault, nil until `.ready`.
    var vault: LocalVault? {
        if case .ready(let vault) = state { return vault }
        return nil
    }

    /// The vault is open, sync joined and the app unlocked: the hosts and sessions are on screen.
    var isReady: Bool {
        vault != nil && isJoined && !appLock.isLocked
    }

    /// Whether this device has joined the sync server (otherwise the join screen shows).
    var isJoined: Bool {
        sync.map { CompanionJoin.isJoined($0.phase) } ?? false
    }

    /// Loads the Keychain key and opens `Application Support/SwiftSSH/vault.bin`. Runs once per
    /// launch; a failed load is only tried again through `retry()`.
    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        await openVault()
    }

    /// Tries again after a failed load.
    func retry() async {
        guard case .failed = state else { return }
        await openVault()
    }

    private func openVault() async {
        state = .loading
        do {
            let fileURL = try Self.vaultFileURL()
            let provider = keyProvider
            // Keychain calls can block: keep them off the main actor.
            let key = try await Task.detached(priority: .userInitiated) { try provider.loadOrCreateKey() }.value
            let vault = try await LocalVault.open(persistence: EncryptedFileVaultPersistence(fileURL: fileURL, key: key))
            let knownHosts = KnownHostsStore(vault: vault)
            self.knownHosts = knownHosts
            hosts = HostsViewModel(vault: vault)
            sessions = makeSessionManager(vault: vault, knownHosts: knownHosts)
            let coordinator = SyncCoordinator(vault: vault, secrets: syncSecrets)
            sync = coordinator
            join = CompanionJoin(coordinator: coordinator)
            state = .ready(vault)
            coordinator.start()
        } catch VaultLoadError.unreadable(let movedTo) {
            // Everything in it came from sync: joining again brings it back.
            state = .failed("The vault on this device couldn\u{2019}t be read, so it was set aside (\(movedTo.lastPathComponent)). "
                            + "Try again to start fresh, then join your sync server again.")
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            state = .failed("The vault could not be opened: \(detail)")
        }
    }

    private func makeSessionManager(vault: LocalVault, knownHosts: KnownHostsStore) -> SessionManager {
        let library = importedKeys
        return SessionManager(
            vault: vault,
            knownHosts: knownHosts,
            makeSession: { plan, evaluator in CitadelSession(plan: plan, hostKeys: evaluator) },
            deviceName: UIDevice.current.name,
            defaultUsername: NSUserName(),
            recordsHostUpdates: false,
            hostPlanner: { hostID, vault in try Self.plan(hostID: hostID, vault: vault, library: library) }
        )
    }

    /// Plans without reading any private key first: only a host that signs in with a key from
    /// 1Password needs the imported keys. Reading them never prompts (`KeychainImportedKeyStorage`):
    /// without a recent Face ID / passcode check it fails, and the plan says the keys are locked
    /// (`connect` and `reconnect` ask first, off the main thread's way).
    private static func plan(hostID: UUID, vault: LocalVault, library: ImportedKeyLibrary) throws -> ConnectionPlan {
        do {
            return try ConnectionPlanner.plan(hostID: hostID, vault: vault, platform: .ios, importedKeys: [])
        } catch ConnectionPlanError.noImportedKeys(let label) where !library.keys.isEmpty {
            let candidates: [SSHKeyCandidate]
            do {
                candidates = try library.candidates()
            } catch let error where KeychainImportedKeyStorage.isLockedError(error) {
                throw ConnectionPlanError.importedKeysLocked(hostLabel: label)
            }
            return try ConnectionPlanner.plan(hostID: hostID, vault: vault, platform: .ios, importedKeys: candidates)
        }
    }

    // MARK: Connecting

    /// Opens a session for the saved host and shows it. A host that signs in with an imported key
    /// asks for Face ID / the passcode first (cancelling opens nothing); password hosts never do.
    /// When the host can't be planned (no address, a key that isn't imported, an RSA key…) no session
    /// opens and `connectProblem` says why.
    func connect(hostID: UUID) async {
        guard let sessions else { return }
        guard await unlockKeysIfNeeded(hostID: hostID) else { return }
        do {
            try sessions.open(hostID: hostID)
        } catch {
            connectProblem = ConnectProblem(error)
        }
    }

    /// Start Over / Reconnect: the same Face ID check first, for a host that needs it.
    func reconnect(tabID: UUID) async {
        guard let sessions, let tab = sessions.tabs.first(where: { $0.id == tabID }) else { return }
        if let hostID = tab.savedHostID {
            guard await unlockKeysIfNeeded(hostID: hostID) else { return }
        }
        sessions.reconnect(tabID: tabID)
    }

    /// True when the host needs no imported keys, there are none to read, or the check passed.
    private func unlockKeysIfNeeded(hostID: UUID) async -> Bool {
        guard let vault, !importedKeys.keys.isEmpty,
              CompanionConnect.needsImportedKeys(hostID: hostID, vault: vault) else { return true }
        return await keyStorage.authorize(reason: "Use your imported SSH key")
    }

    // MARK: Leaving sync and key files

    /// Settings → Leave sync: closes every session, then forgets the sync setup and deletes the local
    /// data and the imported keys (`CompanionJoin.leave`). The join screen shows next.
    func leaveSync() async throws {
        guard let vault, let join else { return }
        await sessions?.closeAll()
        terminalViews.retain(only: [])
        hosts?.searchText = ""
        hosts?.openGroup(nil)
        navigation.show(.hosts)
        try await join.leave(vault: vault, keys: importedKeys)
    }

    /// A key file opened in SwiftSSH ("Open in SwiftSSH", the share sheet, Files): read it and hand
    /// it to the Keys screen's import form. iOS gives the app its own copy (in Documents/Inbox); that
    /// copy is deleted at once, so no private key is left on disk outside the Keychain.
    func openKeyFile(_ url: URL) {
        guard url.isFileURL else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            if Self.isInboxCopy(url) { try? FileManager.default.removeItem(at: url) }
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 64 * 1024, let data = try? Data(contentsOf: url) else { return }
        sessions?.selectedTabID = nil
        navigation.openKeyFile(data: data, name: url.lastPathComponent)
    }

    /// Whether `url` is the app's own copy of an opened file (Documents/Inbox).
    private static func isInboxCopy(_ url: URL) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(inbox + "/")
    }

    // MARK: Lifecycle

    /// The app went to the background.
    func didEnterBackground() {
        appLock.didEnterBackground()
    }

    /// The app is active again.
    func didBecomeActive() {
        appLock.didBecomeActive()
    }

    // MARK: Files

    /// `Application Support/SwiftSSH/vault.bin`; creates the folder if needed.
    static func vaultFileURL() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("SwiftSSH", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("vault.bin", isDirectory: false)
    }
}

/// A host that couldn't be opened: the message, and whether importing a key would help.
struct ConnectProblem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Offer "Import Key" (a 1Password key isn't imported on this device).
    let offersImport: Bool

    init(_ error: any Error) {
        let planError = error as? ConnectionPlanError
        title = planError?.alertTitle ?? "Can\u{2019}t connect"
        message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        if case .noImportedKeys = planError {
            offersImport = true
        } else {
            offersImport = false
        }
    }
}
