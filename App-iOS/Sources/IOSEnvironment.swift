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
    let importedKeys: ImportedKeyLibrary
    let keyStorage: KeychainImportedKeyStorage
    let appLock: AppLock

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
    /// 1Password needs the imported keys, and reading them asks for Face ID.
    private static func plan(hostID: UUID, vault: LocalVault, library: ImportedKeyLibrary) throws -> ConnectionPlan {
        do {
            return try ConnectionPlanner.plan(hostID: hostID, vault: vault, platform: .ios, importedKeys: [])
        } catch ConnectionPlanError.noImportedKeys(_) where !library.keys.isEmpty {
            return try ConnectionPlanner.plan(hostID: hostID, vault: vault, platform: .ios,
                                              importedKeys: library.candidates())
        }
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
