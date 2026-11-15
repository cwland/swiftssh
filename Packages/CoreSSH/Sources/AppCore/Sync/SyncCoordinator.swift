import Foundation
import Observation
import CoreModels
import SyncCore

/// Runs sync for the app (spec §7): setup (connect, create or join the vault), the background
/// loop and the status that Settings → Sync and the Vaults cloud icon show.
///
/// The loop syncs at `start()`, every `interval`, and `debounce` after a local edit (never after
/// records applied from a pull). One sync runs at a time. When the server is unreachable (or
/// answers 5xx) the phase is `.offline` and retries back off 5 s, 10 s … up to 5 min, returning to
/// `interval` after a success. Unauthorized, tampered records and a replaced vault set `.failed`
/// and pause the loop until the user acts (`syncNow()`, join again, or disconnect).
///
/// Secrets go only through `SyncSecretsStore`; they are read at `start()` and kept in memory,
/// and never appear in `phase`, errors or logs.
@MainActor @Observable
public final class SyncCoordinator {
    public enum Phase: Equatable, Sendable {
        /// No server URL / API key yet.
        case notConfigured
        /// Connected; create (`exists == false`) or join (`true`) the vault.
        case needsVault(exists: Bool)
        /// Configured but no vault key on this Mac (ask for the passphrase → join).
        case locked
        /// Synced, waiting.
        case idle
        case syncing
        /// Server unreachable; retrying.
        case offline(String)
        /// Needs attention (unauthorized, tampered record, vault changed…).
        case failed(String)
    }

    static let serverURLKey = "sync.serverURL"
    static let lastSyncedAtKey = "sync.lastSyncedAt"
    /// The vault id the saved vault key belongs to; a key is only used for that vault.
    static let vaultKeyVaultIDKey = "sync.vaultKeyVaultID"
    static let firstBackoff: Duration = .seconds(5)
    static let maxBackoff: Duration = .seconds(300)

    public private(set) var phase: Phase = .notConfigured
    /// Persisted in `UserDefaults` under "sync.lastSyncedAt"; restored at init.
    public private(set) var lastSyncedAt: Date?
    public private(set) var lastReport: SyncReport?
    /// Persisted in `UserDefaults` under "sync.serverURL".
    public private(set) var serverURL: URL?
    /// The last failure that the phase alone can't show: a `disconnect()` Keychain cleanup failure,
    /// or a create/join error that moved the phase to the other form. Cleared by the next
    /// successful `connect`, `createVault`, `joinVault`, `disconnect` or `updateAPIKey`.
    public private(set) var lastError: SyncSetupError?

    @ObservationIgnored private let vault: LocalVault
    @ObservationIgnored private let secrets: any SyncSecretsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeTransport: @Sendable (URL, String) -> any SyncTransport
    @ObservationIgnored private let iterations: Int
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var engine: SyncEngine?
    /// The transport `engine` uses, for checks outside a sync (health after a vault 404).
    @ObservationIgnored private var transport: (any SyncTransport)?
    /// `start()` couldn't read the Keychain; `start()` or `syncNow()` tries again.
    @ObservationIgnored private var secretsReadFailed = false
    /// A vault key loaded at `start()` that the engine hasn't been given yet.
    @ObservationIgnored private var pendingUnlockKey: VaultKey?
    /// True once the engine holds the vault key.
    @ObservationIgnored private var unlocked = false
    /// Between `start()` (or a successful create/join) and `stop()`/`disconnect()`.
    @ObservationIgnored private var running = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var loopGeneration = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var lockCheckTask: Task<Void, Never>?
    @ObservationIgnored private var currentSync: Task<Void, Never>?
    @ObservationIgnored private var requestedSyncs = 0
    @ObservationIgnored private var completedSyncs = 0
    @ObservationIgnored private var outcome: Outcome = .success
    @ObservationIgnored private var offlineStreak = 0

    private enum Outcome {
        case success, offline, paused, error
    }

    public init(vault: LocalVault, secrets: any SyncSecretsStore, defaults: UserDefaults = .standard,
                makeTransport: @escaping @Sendable (URL, String) -> any SyncTransport = {
                    HTTPSyncTransport(baseURL: $0, apiKey: $1)
                },
                iterations: Int = VaultCrypto.defaultIterations,
                interval: Duration = .seconds(60), debounce: Duration = .seconds(3),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.vault = vault
        self.secrets = secrets
        self.defaults = defaults
        self.makeTransport = makeTransport
        self.iterations = iterations
        self.interval = interval
        self.debounce = debounce
        self.sleep = sleep
        self.now = now
        self.serverURL = defaults.string(forKey: Self.serverURLKey).flatMap(URL.init(string:))
        self.lastSyncedAt = defaults.object(forKey: Self.lastSyncedAtKey) as? Date
    }

    // MARK: Validation

    /// http/https only, a host is required, no query or fragment; a path prefix is kept.
    public static func validateServerURL(_ text: String) -> Result<URL, SyncSetupError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              let url = components.url
        else { return .failure(.invalidURL) }
        return .success(url)
    }

    /// nil = OK; otherwise why the passphrase is too weak (fewer than 12 non-blank characters).
    public static func passphraseProblem(_ passphrase: String) -> String? {
        passphrase.trimmingCharacters(in: .whitespacesAndNewlines).count < 12
            ? "Use at least 12 characters." : nil
    }

    // MARK: Setup

    /// Checks the server and the key without saving anything. `true` = a vault exists.
    public func testConnection(serverURL: URL, apiKey: String) async -> Result<Bool, SyncSetupError> {
        let transport = makeTransport(serverURL, apiKey)
        do {
            try await transport.health()
            return .success(try await transport.getVault() != nil)
        } catch {
            return .failure(SyncSetupError(error))
        }
    }

    /// Tests the connection, then saves the URL and the API key; phase → `.needsVault(exists:)`.
    public func connect(serverURL: URL, apiKey: String) async throws(SyncSetupError) {
        let exists = try await testConnection(serverURL: serverURL, apiKey: apiKey).get()
        stopLoop()
        do {
            try secrets.saveAPIKey(apiKey)
        } catch {
            throw .other("The API key couldn't be saved in the Keychain.")
        }
        defaults.set(serverURL.absoluteString, forKey: Self.serverURLKey)
        self.serverURL = serverURL
        makeEngine(serverURL: serverURL, apiKey: apiKey)
        vault.syncClearMergeJoin()
        secretsReadFailed = false
        lastError = nil
        phase = .needsVault(exists: exists)
    }

    /// Creates the vault, saves its key and runs the first sync (uploading this Mac's data).
    /// When another Mac created a vault meanwhile, throws `.vaultAlreadyExists` and the phase
    /// becomes `.needsVault(exists: true)` (join it instead).
    public func createVault(passphrase: String) async throws(SyncSetupError) {
        if Self.passphraseProblem(passphrase) != nil { throw .weakPassphrase }
        let engine = try requireEngine()
        let key: VaultKey
        do {
            key = try await engine.createVault(passphrase: passphrase)
            try saveVaultKey(key)
        } catch {
            let setupError = SyncSetupError(error)
            await engine.lock()
            unlocked = false
            pendingUnlockKey = nil
            if setupError == .vaultAlreadyExists {
                // The view switches to the join form; keep the reason visible there.
                lastError = setupError
                phase = .needsVault(exists: true)
            }
            throw setupError
        }
        vault.syncClearMergeJoin()
        lastError = nil
        await beginSyncing()
    }

    /// Joins the server's vault, saves its key and runs the first sync. `.merge` pulls the vault
    /// first and drops local hosts, identities and keys that match vault ones (`JoinDeduplicator`),
    /// re-pointing references; `.replace` discards this Mac's data.
    ///
    /// A merge join remembers (with the vault) which records were local before it started, so a
    /// retry after a failure or a relaunch still de-duplicates against everything pulled. If the
    /// join fails, nothing syncs with the new key: the engine is locked again and the phase is
    /// `.needsVault(exists: true)` (it stays `.locked` when it was), or `.needsVault(exists: false)`
    /// with `lastError = .noVault` when the server has no vault.
    public func joinVault(passphrase: String, mode: JoinMode) async throws(SyncSetupError) {
        let engine = try requireEngine()
        let wasLocked = phase == .locked
        stopLoop()
        unlocked = false
        pendingUnlockKey = nil
        let key: VaultKey
        do {
            key = try await engine.join(passphrase: passphrase, mode: mode)
            if case .merge = mode {
                let localIDs = try await vault.syncBeginMergeJoin()
                _ = try await engine.pull()
                let all = vault.allRecords
                let plan = JoinDeduplicator.plan(local: all.filter { localIDs.contains($0.id) },
                                                 vault: all.filter { !localIDs.contains($0.id) })
                try await vault.applyJoinPlan(plan, localIDs: localIDs)
            }
            try saveVaultKey(key)
        } catch {
            let setupError = SyncSetupError(error)
            await engine.lock()
            unlocked = false
            pendingUnlockKey = nil
            if setupError == .noVault {
                // The view switches to the create form; keep the reason visible there.
                lastError = setupError
                phase = .needsVault(exists: false)
            } else if !wasLocked {
                phase = .needsVault(exists: true)
            }
            throw setupError
        }
        lastError = nil
        await beginSyncing()
    }

    /// Replaces the API key (e.g. after the server's keys were rotated): checks `key` against the
    /// server first (it must be accepted), saves it and, when this Mac has the vault key, resumes
    /// syncing at once — no passphrase needed. Without a vault key the phase becomes `.locked`
    /// (vault exists) or `.needsVault(exists: false)`. A rejected key changes nothing.
    public func updateAPIKey(_ key: String) async throws(SyncSetupError) {
        guard let serverURL else { throw .other("Connect to a sync server first.") }
        let exists = try await testConnection(serverURL: serverURL, apiKey: key).get()
        let vaultKey: VaultKey?
        do {
            vaultKey = try loadVaultKeyForCurrentVault()
        } catch {
            throw .keychainUnreadable
        }
        do {
            try secrets.saveAPIKey(key)
        } catch {
            throw .other("The API key couldn't be saved in the Keychain.")
        }
        stopLoop()
        currentSync?.cancel()
        makeEngine(serverURL: serverURL, apiKey: key)
        secretsReadFailed = false
        lastError = nil
        guard let vaultKey else {
            phase = exists ? .locked : .needsVault(exists: false)
            return
        }
        pendingUnlockKey = vaultKey
        unlocked = true
        await beginSyncing()
    }

    /// Re-wraps the vault key under `new`. Records and this Mac's saved vault key are unchanged.
    public func changePassphrase(old: String, new: String) async throws(SyncSetupError) {
        if Self.passphraseProblem(new) != nil { throw .weakPassphrase }
        let engine = try requireEngine()
        do {
            try await engine.changePassphrase(old: old, new: new)
        } catch {
            throw SyncSetupError(error)
        }
    }

    // MARK: Lifecycle

    /// At launch: configured with a vault key → unlock and start the loop; configured without
    /// one → `.locked` (or `.needsVault(exists: false)` once the server says it has no vault).
    /// Idempotent: a second call without `stop()` does nothing; after `stop()` it starts again.
    ///
    /// A saved vault key is used only for the vault it was saved with (`sync.vaultKeyVaultID`);
    /// otherwise the phase is `.needsVault(exists: true)` and nothing syncs until a join succeeds.
    ///
    /// If the Keychain can't be read, the phase is `.failed(SyncSetupError.keychainUnreadable.message)`
    /// (not "not configured"); `start()` or `syncNow()` tries again.
    public func start() {
        start(syncFirst: true)
    }

    private func start(syncFirst: Bool) {
        guard !running else { return }
        running = true
        secretsReadFailed = false
        serverURL = defaults.string(forKey: Self.serverURLKey).flatMap(URL.init(string:))
        guard let serverURL else {
            phase = .notConfigured
            return
        }
        let apiKey: String?
        do {
            apiKey = try secrets.loadAPIKey()
        } catch {
            return secretsUnreadable()
        }
        guard let apiKey, !apiKey.isEmpty else {
            phase = .notConfigured
            return
        }
        if engine == nil { makeEngine(serverURL: serverURL, apiKey: apiKey) }
        if unlocked {
            startLoop(syncFirst: syncFirst)
            return
        }
        let savedKey: VaultKey?
        do {
            savedKey = try secrets.loadVaultKey()
        } catch {
            return secretsUnreadable()
        }
        if savedKey != nil, !savedKeyBelongsToCurrentVault {
            // A key for another vault (a join was interrupted or failed after the vault id
            // changed): never unlock with it; ask for the passphrase again.
            phase = .needsVault(exists: true)
            return
        }
        guard let key = savedKey else {
            phase = .locked
            checkForMissingVault(serverURL: serverURL, apiKey: apiKey)
            return
        }
        pendingUnlockKey = key
        unlocked = true
        phase = .idle
        startLoop(syncFirst: syncFirst)
    }

    /// A Keychain read failed in `start()`: show it, and let `start()` / `syncNow()` retry.
    private func secretsUnreadable() {
        running = false
        secretsReadFailed = true
        phase = .failed(SyncSetupError.keychainUnreadable.message)
    }

    /// Syncs now (also retrying after `.failed`); waits until a sync that started after this call
    /// has finished. Does nothing until configured and unlocked.
    public func syncNow() async {
        if secretsReadFailed {
            start(syncFirst: false)
            if secretsReadFailed { return }
        }
        requestedSyncs += 1
        let request = requestedSyncs
        while completedSyncs < request {
            if let currentSync {
                await currentSync.value
                continue
            }
            let covers = requestedSyncs
            currentSync = Task { @MainActor in
                await self.performSync()
                self.completedSyncs = max(self.completedSyncs, covers)
                self.currentSync = nil
            }
        }
        if running, outcome != .paused { startLoop(syncFirst: false) }
    }

    /// Stops syncing and forgets this Mac's sync setup: deletes the API key and vault key, the
    /// server URL and the sync state. Local data is kept.
    /// If the Keychain refuses to delete the keys, the rest still happens and `lastError` is
    /// `.keychainCleanupFailed`.
    public func disconnect() {
        stop()
        do {
            try secrets.deleteAll()
            lastError = nil
        } catch {
            lastError = .keychainCleanupFailed
        }
        defaults.removeObject(forKey: Self.serverURLKey)
        defaults.removeObject(forKey: Self.lastSyncedAtKey)
        defaults.removeObject(forKey: Self.vaultKeyVaultIDKey)
        serverURL = nil
        engine = nil
        transport = nil
        secretsReadFailed = false
        unlocked = false
        pendingUnlockKey = nil
        lastSyncedAt = nil
        lastReport = nil
        outcome = .success
        offlineStreak = 0
        vault.syncResetState()
        phase = .notConfigured
    }

    /// Stops the loop and any running sync (app quit). `start()` resumes.
    public func stop() {
        running = false
        stopLoop()
        lockCheckTask?.cancel()
        lockCheckTask = nil
        currentSync?.cancel()
        vault.localChangeHandler = nil
    }

    // MARK: Internals

    private func makeEngine(serverURL: URL, apiKey: String) {
        let transport = makeTransport(serverURL, apiKey)
        self.transport = transport
        engine = SyncEngine(transport: transport, store: LocalVaultSyncStore(vault: vault),
                            deviceID: vault.deviceID, iterations: iterations)
        unlocked = false
        pendingUnlockKey = nil
    }

    private func requireEngine() throws(SyncSetupError) -> SyncEngine {
        guard let engine else { throw .other("Connect to a sync server first.") }
        return engine
    }

    /// Saves the key and records which vault it belongs to (the vault id create/join just stored).
    private func saveVaultKey(_ key: VaultKey) throws(SyncSetupError) {
        defaults.removeObject(forKey: Self.vaultKeyVaultIDKey)
        do {
            try secrets.saveVaultKey(key)
        } catch {
            throw .other("The vault key couldn't be saved in the Keychain.")
        }
        if let vaultID = vault.currentSyncState.vaultID {
            defaults.set(vaultID.uuidString, forKey: Self.vaultKeyVaultIDKey)
        }
        unlocked = true
        pendingUnlockKey = nil
    }

    /// True when the saved vault key was saved for the vault this Mac's sync state names.
    private var savedKeyBelongsToCurrentVault: Bool {
        guard let vaultID = vault.currentSyncState.vaultID,
              let bound = defaults.string(forKey: Self.vaultKeyVaultIDKey) else { return false }
        return UUID(uuidString: bound) == vaultID
    }

    /// The saved vault key if it belongs to the current vault, else nil. Throws on a Keychain error.
    private func loadVaultKeyForCurrentVault() throws -> VaultKey? {
        guard let key = try secrets.loadVaultKey(), savedKeyBelongsToCurrentVault else { return nil }
        return key
    }

    /// After a create or join: first sync, then the loop.
    private func beginSyncing() async {
        running = true
        outcome = .success
        offlineStreak = 0
        await syncNow()
    }

    /// While `.locked`: if the server has no vault, offer to create one instead.
    private func checkForMissingVault(serverURL: URL, apiKey: String) {
        lockCheckTask = Task { [weak self] in
            guard let result = await self?.testConnection(serverURL: serverURL, apiKey: apiKey),
                  !Task.isCancelled, let self, self.phase == .locked else { return }
            if case .success(false) = result { self.phase = .needsVault(exists: false) }
        }
    }

    private func performSync() async {
        guard let engine, unlocked else { return }
        if let key = pendingUnlockKey {
            await engine.unlock(with: key)
            pendingUnlockKey = nil
        }
        phase = .syncing
        do {
            let report = try await engine.sync()
            // Disconnected or reconnected meanwhile: this result belongs to the old setup.
            guard self.engine === engine else { return }
            lastReport = report
            let syncedAt = now()
            lastSyncedAt = syncedAt
            defaults.set(syncedAt, forKey: Self.lastSyncedAtKey)
            offlineStreak = 0
            outcome = .success
            phase = .idle
        } catch is CancellationError {
            if self.engine === engine { phase = .idle }
        } catch {
            guard self.engine === engine else { return }
            var setupError = SyncSetupError(error)
            var healthFailed = false
            if setupError == .vaultChanged, let transport {
                (setupError, healthFailed) = await diagnoseMissingVault(transport)
                guard self.engine === engine else { return }
            }
            switch setupError {
            case _ where healthFailed:
                outcome = .offline
                phase = .offline(setupError.message)
            case .unreachable:
                outcome = .offline
                phase = .offline(setupError.message)
            case .server(let status) where status >= 500:
                outcome = .offline
                phase = .offline(setupError.message)
            case .unauthorized, .tampered, .vaultChanged, .noVault, .noVaultAtAddress:
                outcome = .paused
                phase = .failed(setupError.message)
            default:
                outcome = .error
                phase = .failed(setupError.message)
            }
            if outcome == .offline { offlineStreak += 1 } else { offlineStreak = 0 }
        }
    }

    /// The engine reports `.vaultChanged` both when `GET /v1/vault` is 404 and when it names another
    /// vault. A 404 may be a proxy problem, so `/health` is asked first: if it fails, that error is
    /// returned with `healthFailed` (shown as offline, retried with backoff). Otherwise the vault is
    /// fetched again: still missing → `.noVaultAtAddress`; another vault → `.vaultChanged`; this
    /// vault back again → a transient answer, treated as unreachable.
    private func diagnoseMissingVault(_ transport: any SyncTransport) async
        -> (error: SyncSetupError, healthFailed: Bool) {
        do {
            try await transport.health()
        } catch {
            return (SyncSetupError(error), true)
        }
        do {
            guard let metadata = try await transport.getVault() else { return (.noVaultAtAddress, false) }
            if metadata.vaultID != vault.currentSyncState.vaultID { return (.vaultChanged, false) }
            return (.unreachable("the server's answer changed while syncing"), false)
        } catch {
            return (SyncSetupError(error), false)
        }
    }

    /// Delay before the next automatic sync, or nil when paused.
    private var nextDelay: Duration? {
        switch outcome {
        case .success, .error: return interval
        case .paused: return nil
        case .offline:
            var delay = Self.firstBackoff
            for _ in 1 ..< max(offlineStreak, 1) where delay < Self.maxBackoff { delay *= 2 }
            return min(delay, Self.maxBackoff)
        }
    }

    /// Starts the loop if it should run and isn't running; `syncFirst` = sync before the first wait.
    private func startLoop(syncFirst: Bool) {
        guard running, loopTask == nil, engine != nil, unlocked else { return }
        vault.localChangeHandler = { [weak self] in self?.localChange() }
        loopGeneration += 1
        let generation = loopGeneration
        loopTask = Task { [weak self] in
            var syncNext = syncFirst
            while !Task.isCancelled {
                guard let self else { return }
                if syncNext { await self.syncNow() }
                syncNext = true
                guard !Task.isCancelled, let delay = self.nextDelay else { break }
                do { try await self.sleep(delay) } catch { break }
            }
            if let self, self.loopGeneration == generation { self.loopTask = nil }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        loopGeneration += 1
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func localChange() {
        guard running, loopTask != nil, unlocked, outcome != .paused else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce = self.debounce, sleep = self.sleep] in
            do { try await sleep(debounce) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }
}
