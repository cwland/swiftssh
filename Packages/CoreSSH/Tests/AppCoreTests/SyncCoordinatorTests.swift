import XCTest
import CoreModels
import SyncCore
import SyncTestSupport
@testable import AppCore

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

/// Forwards to an `InMemoryTransport` (the server's rules) and can fail calls on demand.
actor ScriptedTransport: SyncTransport {
    let server: InMemoryTransport
    private var failures: [Error] = []
    private var failForever: Error?
    private var pageLimit = Int.max
    private var fetchFailure: (remainingSuccesses: Int, error: Error)?
    private(set) var syncAttempts = 0

    init(server: InMemoryTransport = InMemoryTransport()) {
        self.server = server
    }

    /// The next `count` `getVault` calls (one per sync) throw `error`.
    func fail(_ count: Int, with error: Error) {
        failures += Array(repeating: error, count: count)
    }

    func failAlways(_ error: Error?) {
        failForever = error
    }

    /// Every `fetch` returns at most `limit` records per page.
    func limitPages(to limit: Int) {
        pageLimit = limit
    }

    /// After `count` more successful `fetch` calls, the next one throws `error` (once).
    func failFetch(afterSuccessfulCalls count: Int, with error: Error) {
        fetchFailure = (count, error)
    }

    private var healthFailure: Error?

    /// `health()` throws `error` (nil: it follows `failAlways`).
    func failHealth(_ error: Error?) {
        healthFailure = error
    }

    func health() async throws {
        if let healthFailure { throw healthFailure }
        if let failForever { throw failForever }
    }

    func getVault() async throws -> VaultMetadata? {
        syncAttempts += 1
        if let failForever { throw failForever }
        if !failures.isEmpty { throw failures.removeFirst() }
        return try await server.getVault()
    }

    func putVault(_ metadata: VaultMetadata) async throws { try await server.putVault(metadata) }
    func rewrap(_ request: RewrapRequest) async throws -> VaultMetadata { try await server.rewrap(request) }
    func fetch(since: Int64, limit: Int) async throws -> RecordsPage {
        if let failure = fetchFailure {
            if failure.remainingSuccesses == 0 {
                fetchFailure = nil
                throw failure.error
            }
            fetchFailure = (failure.remainingSuccesses - 1, failure.error)
        }
        return try await server.fetch(since: since, limit: min(limit, pageLimit))
    }
    func upsert(_ records: [EncryptedRecord]) async throws -> [EncryptedRecord] { try await server.upsert(records) }
}

/// Records every requested sleep. Durations in `immediate` return at once (after a yield);
/// any other duration suspends until the task is cancelled. Throws once `limit` sleeps were seen.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    let immediate: Set<Duration>
    let limit: Int

    init(immediate: Set<Duration> = [], limit: Int = .max) {
        self.immediate = immediate
        self.limit = limit
    }

    var durations: [Duration] { lock.withLock { _durations } }

    func sleep(_ duration: Duration) async throws {
        let count = lock.withLock { _durations.append(duration); return _durations.count }
        if count >= limit { throw CancellationError() }
        if immediate.contains(duration) {
            await Task.yield()
        } else {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private let url = URL(string: "https://proxy.example/sync/")!
    private let apiKey = "api-key-123456"
    private let passphrase = "correct horse battery"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults() -> UserDefaults {
        let name = "sync-tests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private struct Mac {
        let vault: LocalVault
        let secrets: InMemorySyncSecretsStore
        let defaults: UserDefaults
        let coordinator: SyncCoordinator
        let sleeps: SleepRecorder
    }

    private func mac(_ device: String, transport: ScriptedTransport, persistence: InMemoryVaultPersistence? = nil,
                     secrets: InMemorySyncSecretsStore = InMemorySyncSecretsStore(), defaults: UserDefaults? = nil,
                     sleeps: SleepRecorder = SleepRecorder(), now: Date = Date(timeIntervalSince1970: 5_000))
        async throws -> Mac {
        let vault = try await LocalVault.open(persistence: persistence ?? InMemoryVaultPersistence(),
                                              newDeviceID: { device })
        let defaults = defaults ?? self.defaults()
        let coordinator = SyncCoordinator(vault: vault, secrets: secrets, defaults: defaults,
                                          makeTransport: { _, _ in transport }, iterations: 1_000,
                                          interval: .seconds(60), debounce: .seconds(3),
                                          sleep: { try await sleeps.sleep($0) }, now: { now })
        return Mac(vault: vault, secrets: secrets, defaults: defaults, coordinator: coordinator, sleeps: sleeps)
    }

    private func eventually(_ what: String = "condition", timeout: Double = 5,
                            _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: Validation

    func testValidateServerURL() async {
        let ok = SyncCoordinator.validateServerURL("  https://proxy.example/sync/ ")
        XCTAssertEqual(try? ok.get().absoluteString, "https://proxy.example/sync/")
        XCTAssertEqual(try? SyncCoordinator.validateServerURL("http://nas.lan:8080").get().absoluteString,
                       "http://nas.lan:8080")
        for bad in ["", "nas.lan", "ftp://nas.lan", "https://", "https:///sync", "not a url", "https://h/x?y=1"] {
            XCTAssertEqual(SyncCoordinator.validateServerURL(bad), .failure(.invalidURL), bad)
        }
    }

    func testPassphraseProblem() async {
        XCTAssertNotNil(SyncCoordinator.passphraseProblem("short"))
        XCTAssertNotNil(SyncCoordinator.passphraseProblem("           "))
        XCTAssertNil(SyncCoordinator.passphraseProblem("twelve chars"))
    }

    func testErrorMessagesAreShortAndPresent() async {
        let all: [SyncSetupError] = [.invalidURL, .unreachable("the connection was refused"), .unauthorized,
                                     .server(500), .wrongPassphrase, .vaultAlreadyExists, .noVault,
                                     .weakPassphrase, .vaultChanged, .tampered, .other("x")]
        for error in all { XCTAssertFalse(error.message.isEmpty) }
        XCTAssertTrue(SyncSetupError.unreachable("the connection was refused").message.contains("refused"))
    }

    func testRedirectAndATSErrorsHaveActionableMessages() async {
        let redirect = "The sync server redirected the request. Use the final address (check your proxy) in Settings → Sync."
        XCTAssertEqual(SyncSetupError(SyncTransportError.redirected), .redirected)
        XCTAssertEqual(SyncSetupError.redirected.message, redirect)
        let ats = "macOS blocked a plain http:// connection. Use your https:// proxy address."
        XCTAssertEqual(SyncSetupError(SyncTransportError.insecureConnectionBlocked), .insecureConnectionBlocked)
        XCTAssertEqual(SyncSetupError(URLError(.appTransportSecurityRequiresSecureConnection)), .insecureConnectionBlocked)
        XCTAssertEqual(SyncSetupError.insecureConnectionBlocked.message, ats)
    }

    // MARK: Connecting

    func testTestConnectionReportsVaultExistenceAndSavesNothing() async throws {
        let transport = ScriptedTransport()
        let m = try await mac("mbp", transport: transport)
        let none = await m.coordinator.testConnection(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(none, .success(false))
        try await transport.server.putVault(VaultMetadata(vaultID: UUID(), salt: Data(count: 16), iterations: 1_000,
                                                          wrappedKey: Data(count: 60)))
        let exists = await m.coordinator.testConnection(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(exists, .success(true))
        XCTAssertNil(try m.secrets.loadAPIKey())
        XCTAssertNil(m.defaults.string(forKey: "sync.serverURL"))
        XCTAssertEqual(m.coordinator.phase, .notConfigured)
    }

    func testTestConnectionMapsErrors() async throws {
        let transport = ScriptedTransport()
        let m = try await mac("mbp", transport: transport)
        await transport.failAlways(SyncTransportError.unauthorized)
        let unauthorized = await m.coordinator.testConnection(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(unauthorized, .failure(.unauthorized))
        await transport.failAlways(SyncTransportError.unreachable("the connection was refused"))
        let unreachable = await m.coordinator.testConnection(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(unreachable, .failure(.unreachable("the connection was refused")))
        await transport.failAlways(SyncTransportError.http(status: 404, message: ""))
        let notFound = await m.coordinator.testConnection(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(notFound, .failure(.server(404)))
    }

    func testConnectSavesURLAndKeyAndAsksForAVault() async throws {
        let transport = ScriptedTransport()
        var seen: (URL, String)?
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "mbp" })
        let secrets = InMemorySyncSecretsStore()
        let defaults = defaults()
        let box = SeenBox()
        let coordinator = SyncCoordinator(vault: vault, secrets: secrets, defaults: defaults,
                                          makeTransport: { url, key in box.set(url, key); return transport },
                                          iterations: 1_000)
        try await coordinator.connect(serverURL: url, apiKey: apiKey)
        seen = box.value
        XCTAssertEqual(seen?.0, url)
        XCTAssertEqual(seen?.1, apiKey)
        XCTAssertEqual(coordinator.phase, .needsVault(exists: false))
        XCTAssertEqual(coordinator.serverURL, url)
        XCTAssertEqual(try secrets.loadAPIKey(), apiKey)
        XCTAssertEqual(defaults.string(forKey: "sync.serverURL"), url.absoluteString)
    }

    func testConnectFailureSavesNothing() async throws {
        let transport = ScriptedTransport()
        await transport.failAlways(SyncTransportError.unauthorized)
        let m = try await mac("mbp", transport: transport)
        do {
            try await m.coordinator.connect(serverURL: url, apiKey: apiKey)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertNil(try m.secrets.loadAPIKey())
        XCTAssertNil(m.coordinator.serverURL)
        XCTAssertEqual(m.coordinator.phase, .notConfigured)
    }

    // MARK: Create and join

    func testCreateVaultRejectsWeakPassphrase() async throws {
        let m = try await mac("mbp", transport: ScriptedTransport())
        try await m.coordinator.connect(serverURL: url, apiKey: apiKey)
        do {
            try await m.coordinator.createVault(passphrase: "short")
            XCTFail("expected weakPassphrase")
        } catch {
            XCTAssertEqual(error, .weakPassphrase)
        }
        XCTAssertNil(try m.secrets.loadVaultKey())
    }

    func testCreateVaultSavesKeyAndUploadsLocalData() async throws {
        let transport = ScriptedTransport()
        let m = try await mac("mbp", transport: transport)
        try await m.vault.save(Host(label: "nas", address: "nas.lan"))
        try await m.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await m.coordinator.createVault(passphrase: passphrase)

        XCTAssertNotNil(try m.secrets.loadVaultKey())
        XCTAssertEqual(m.coordinator.phase, .idle)
        XCTAssertEqual(m.coordinator.lastSyncedAt, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(m.coordinator.lastReport?.pushed, 1)
        let stored = await transport.server.storedRecords
        XCTAssertEqual(stored.count, 1)
        m.coordinator.stop()
    }

    func testCreateVaultWhenOneExists() async throws {
        let transport = ScriptedTransport()
        let a = try await mac("mbp", transport: transport)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()
        let b = try await mac("mini", transport: transport)
        try await b.coordinator.connect(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(b.coordinator.phase, .needsVault(exists: true))
        do {
            try await b.coordinator.createVault(passphrase: passphrase)
            XCTFail("expected vaultAlreadyExists")
        } catch {
            XCTAssertEqual(error, .vaultAlreadyExists)
        }
    }

    func testJoinWithWrongPassphraseSavesNothing() async throws {
        let transport = ScriptedTransport()
        let a = try await mac("mbp", transport: transport)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()
        let b = try await mac("mini", transport: transport)
        let local = try await b.vault.save(Host(label: "pi", address: "pi.lan"))
        try await b.coordinator.connect(serverURL: url, apiKey: apiKey)
        do {
            try await b.coordinator.joinVault(passphrase: "wrong passphrase!", mode: .replace)
            XCTFail("expected wrongPassphrase")
        } catch {
            XCTAssertEqual(error, .wrongPassphrase)
        }
        XCTAssertNil(try b.secrets.loadVaultKey())
        XCTAssertEqual(b.vault.get(Host.self, id: local.id), local)
    }

    func testJoinReplaceTakesTheVaultsData() async throws {
        let transport = ScriptedTransport()
        let a = try await mac("mbp", transport: transport)
        let nas = try await a.vault.save(Host(label: "nas", address: "nas.lan"))
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()

        let b = try await mac("mini", transport: transport)
        try await b.vault.save(Host(label: "pi", address: "pi.lan"))
        try await b.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await b.coordinator.joinVault(passphrase: passphrase, mode: .replace)
        XCTAssertEqual(b.vault.all(Host.self).map(\.id), [nas.id])
        XCTAssertEqual(b.coordinator.phase, .idle)
        XCTAssertNotNil(try b.secrets.loadVaultKey())
        b.coordinator.stop()
    }

    func testCreateVaultWhenAnotherMacCreatedOneMeanwhileOffersJoin() async throws {
        let transport = ScriptedTransport()
        let a = try await mac("mbp", transport: transport)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(a.coordinator.phase, .needsVault(exists: false))
        let b = try await mac("mini", transport: transport)
        try await b.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await b.coordinator.createVault(passphrase: passphrase)
        b.coordinator.stop()
        do {
            try await a.coordinator.createVault(passphrase: passphrase)
            XCTFail("expected vaultAlreadyExists")
        } catch {
            XCTAssertEqual(error, .vaultAlreadyExists)
        }
        XCTAssertEqual(a.coordinator.phase, .needsVault(exists: true))
    }

    func testJoinWhenTheVaultIsGoneOffersCreate() async throws {
        let transport = ScriptedTransport()
        let a = try await mac("mbp", transport: transport)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()
        let b = try await mac("mini", transport: transport)
        try await b.coordinator.connect(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(b.coordinator.phase, .needsVault(exists: true))
        await transport.server.replaceVault(nil)
        do {
            try await b.coordinator.joinVault(passphrase: passphrase, mode: .merge)
            XCTFail("expected noVault")
        } catch {
            XCTAssertEqual(error, .noVault)
        }
        XCTAssertEqual(b.coordinator.phase, .needsVault(exists: false))
    }

    // MARK: Retried merge join

    private func storedHostIDs(_ transport: ScriptedTransport) async -> Set<UUID> {
        Set(await transport.server.storedRecords.filter { $0.type == .host && !$0.deleted }.map(\.id))
    }

    /// The MacBook's vault holds nas + pi; returns their ids. Pages are then one record long.
    private func macBookVault(_ transport: ScriptedTransport) async throws -> (nas: UUID, pi: UUID) {
        let a = try await mac("MacBook", transport: transport)
        let nas = try await a.vault.save(Host(label: "NAS", address: "nas.lan", username: "cory"))
        let pi = try await a.vault.save(Host(label: "pi", address: "pi.lan", username: "pi"))
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()
        await transport.limitPages(to: 1)
        return (nas.id, pi.id)
    }

    private func saveDuplicates(in vault: LocalVault) async throws {
        try await vault.save(Host(label: "nas (mini)", address: "NAS.lan", username: "cory"))
        try await vault.save(Host(label: "pi (mini)", address: "pi.lan", port: 22, username: "pi"))
    }

    func testRetriedMergeJoinAfterAFailedPullUploadsNoDuplicates() async throws {
        let transport = ScriptedTransport()
        let vaultHosts = try await macBookVault(transport)
        let persistence = InMemoryVaultPersistence()
        let mini = try await mac("Mac mini", transport: transport, persistence: persistence)
        try await saveDuplicates(in: mini.vault)
        try await mini.coordinator.connect(serverURL: url, apiKey: apiKey)

        await transport.failFetch(afterSuccessfulCalls: 1, with: SyncTransportError.unreachable("the connection was lost"))
        do {
            try await mini.coordinator.joinVault(passphrase: passphrase, mode: .merge)
            XCTFail("expected the join to fail on page 2")
        } catch {
            XCTAssertEqual(error, .unreachable("the connection was lost"))
        }
        XCTAssertEqual(mini.coordinator.phase, .needsVault(exists: true))
        XCTAssertNil(try mini.secrets.loadVaultKey())

        try await mini.coordinator.joinVault(passphrase: passphrase, mode: .merge)
        let stored = await storedHostIDs(transport)
        XCTAssertEqual(stored, [vaultHosts.nas, vaultHosts.pi])
        XCTAssertEqual(Set(mini.vault.all(Host.self).map(\.id)), [vaultHosts.nas, vaultHosts.pi])
        await mini.vault.flush()
        let marker = await persistence.contents?.mergeJoinLocalIDs
        XCTAssertNil(marker, "the pending-join marker is cleared once the plan is applied")
        mini.coordinator.stop()
    }

    func testMergeJoinInterruptedByQuitThenRetriedUploadsNoDuplicates() async throws {
        let transport = ScriptedTransport()
        let vaultHosts = try await macBookVault(transport)
        let persistence = InMemoryVaultPersistence()
        let mini = try await mac("Mac mini", transport: transport, persistence: persistence)
        try await saveDuplicates(in: mini.vault)
        try await mini.coordinator.connect(serverURL: url, apiKey: apiKey)
        await transport.failFetch(afterSuccessfulCalls: 1, with: SyncTransportError.unreachable("the connection was lost"))
        do {
            try await mini.coordinator.joinVault(passphrase: passphrase, mode: .merge)
            XCTFail("expected the join to fail on page 2")
        } catch {}
        mini.coordinator.stop()
        await mini.vault.flush()

        // The app quits and relaunches: the vault is reopened from its file.
        let relaunched = try await mac("Mac mini", transport: transport, persistence: persistence,
                                       secrets: mini.secrets, defaults: mini.defaults)
        relaunched.coordinator.start()
        XCTAssertEqual(relaunched.coordinator.phase, .locked)
        try await relaunched.coordinator.joinVault(passphrase: passphrase, mode: .merge)
        let stored = await storedHostIDs(transport)
        XCTAssertEqual(stored, [vaultHosts.nas, vaultHosts.pi])
        XCTAssertEqual(Set(relaunched.vault.all(Host.self).map(\.id)), [vaultHosts.nas, vaultHosts.pi])
        relaunched.coordinator.stop()
    }

    /// A Mac that was syncing (unlocked) re-joins a replaced vault and the join fails half-way:
    /// nothing may sync with the half-joined key until the join is retried.
    func testFailedJoinLeavesNothingSyncingWithTheNewKey() async throws {
        let transport = ScriptedTransport()
        let mini = try await mac("Mac mini", transport: transport)
        try await saveDuplicates(in: mini.vault)
        try await mini.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await mini.coordinator.createVault(passphrase: passphrase)
        XCTAssertEqual(mini.coordinator.phase, .idle)

        await transport.server.replaceVault(nil)
        let vaultHosts = try await macBookVault(transport)
        await mini.coordinator.syncNow()
        XCTAssertEqual(mini.coordinator.phase, .failed(SyncSetupError.vaultChanged.message))

        await transport.failFetch(afterSuccessfulCalls: 1, with: SyncTransportError.unreachable("the connection was lost"))
        do {
            try await mini.coordinator.joinVault(passphrase: passphrase, mode: .merge)
            XCTFail("expected the join to fail on page 2")
        } catch {}
        XCTAssertEqual(mini.coordinator.phase, .needsVault(exists: true))
        await mini.coordinator.syncNow()
        XCTAssertEqual(mini.coordinator.phase, .needsVault(exists: true))
        var stored = await storedHostIDs(transport)
        XCTAssertEqual(stored, [vaultHosts.nas, vaultHosts.pi], "nothing uploaded with the half-joined key")

        try await mini.coordinator.joinVault(passphrase: passphrase, mode: .merge)
        stored = await storedHostIDs(transport)
        XCTAssertEqual(stored, [vaultHosts.nas, vaultHosts.pi])
        XCTAssertEqual(mini.coordinator.phase, .idle)
        mini.coordinator.stop()
    }

    // MARK: start / stop

    func testStartWithoutConfigurationIsNotConfigured() async throws {
        let m = try await mac("mbp", transport: ScriptedTransport())
        m.coordinator.start()
        XCTAssertEqual(m.coordinator.phase, .notConfigured)
        XCTAssertNil(m.coordinator.serverURL)
    }

    func testStartWithoutVaultKeyIsLockedOrNeedsVault() async throws {
        let transport = ScriptedTransport()
        let first = try await mac("mbp", transport: transport)
        try await first.coordinator.connect(serverURL: url, apiKey: apiKey)

        let relaunched = try await mac("mbp", transport: transport, secrets: first.secrets, defaults: first.defaults)
        relaunched.coordinator.start()
        XCTAssertEqual(relaunched.coordinator.serverURL, url)
        await eventually("needsVault") { relaunched.coordinator.phase == .needsVault(exists: false) }
        relaunched.coordinator.stop()

        try await transport.server.putVault(VaultMetadata(vaultID: UUID(), salt: Data(count: 16), iterations: 1_000,
                                                          wrappedKey: Data(count: 60)))
        let again = try await mac("mbp", transport: transport, secrets: first.secrets, defaults: first.defaults)
        again.coordinator.start()
        XCTAssertEqual(again.coordinator.phase, .locked)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(again.coordinator.phase, .locked)
        again.coordinator.stop()
    }

    /// Relaunch: the saved URL, API key and vault key unlock and sync without a passphrase.
    func testStartWithVaultKeySyncsAndLoops() async throws {
        let transport = ScriptedTransport()
        let persistence = InMemoryVaultPersistence()
        let a = try await mac("mbp", transport: transport, persistence: persistence)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()
        let other = try await mac("mini", transport: transport)
        try await other.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await other.coordinator.joinVault(passphrase: passphrase, mode: .merge)
        let pi = try await other.vault.save(Host(label: "pi", address: "pi.lan"))
        await other.coordinator.syncNow()
        other.coordinator.stop()

        let relaunched = try await mac("mbp", transport: transport, persistence: persistence,
                                       secrets: a.secrets, defaults: a.defaults)
        relaunched.coordinator.start()
        await eventually("pulled host") { relaunched.vault.get(Host.self, id: pi.id) != nil }
        await eventually("idle") { relaunched.coordinator.phase == .idle }
        await eventually("interval sleep") { relaunched.sleeps.durations == [.seconds(60)] }
        relaunched.coordinator.stop()
    }

    func testStartIsIdempotentAndRestartsAfterStop() async throws {
        let transport = ScriptedTransport()
        let persistence = InMemoryVaultPersistence()
        let a = try await mac("mbp", transport: transport, persistence: persistence)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()

        let sleeps = SleepRecorder()
        let m = try await mac("mbp", transport: transport, persistence: persistence, secrets: a.secrets, defaults: a.defaults, sleeps: sleeps)
        let attemptsBefore = await transport.syncAttempts
        m.coordinator.start()
        m.coordinator.start()
        await eventually("first loop sleep") { sleeps.durations.count == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sleeps.durations, [.seconds(60)], "one loop only")
        let attemptsAfterStart = await transport.syncAttempts
        XCTAssertEqual(attemptsAfterStart - attemptsBefore, 1)

        m.coordinator.stop()
        m.coordinator.start()
        await eventually("restarted loop sleep") { sleeps.durations.count == 2 }
        let attemptsAfterRestart = await transport.syncAttempts
        XCTAssertEqual(attemptsAfterRestart - attemptsBefore, 2)
        XCTAssertEqual(m.coordinator.phase, .idle)
        m.coordinator.stop()
    }

    // MARK: The loop

    func testLocalEditSyncsAfterDebounceButPulledChangesDoNot() async throws {
        let transport = ScriptedTransport()
        let sleeps = SleepRecorder(immediate: [.seconds(3)])
        let a = try await mac("mbp", transport: transport, sleeps: sleeps)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        await eventually("loop sleeping") { sleeps.durations == [.seconds(60)] }

        let host = try await a.vault.save(Host(label: "nas", address: "nas.lan"))
        await eventually("debounced push") { await transport.server.storedRecords.contains { $0.id == host.id } }
        XCTAssertEqual(sleeps.durations.filter { $0 == .seconds(3) }.count, 1)

        let b = try await mac("mini", transport: transport)
        try await b.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await b.coordinator.joinVault(passphrase: passphrase, mode: .merge)
        try await b.vault.save(Host(label: "pi", address: "pi.lan"))
        await b.coordinator.syncNow()
        b.coordinator.stop()

        await a.coordinator.syncNow()
        XCTAssertEqual(a.vault.all(Host.self).count, 2)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sleeps.durations.filter { $0 == .seconds(3) }.count, 1, "pulls don't schedule a sync")
        a.coordinator.stop()
    }

    func testOfflineBacksOffExponentiallyUpToFiveMinutes() async throws {
        let transport = ScriptedTransport()
        let persistence = InMemoryVaultPersistence()
        let a = try await mac("mbp", transport: transport, persistence: persistence)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()

        await transport.failAlways(SyncTransportError.unreachable("the connection was refused"))
        let backoff: Set<Duration> = [5, 10, 20, 40, 80, 160, 300].reduce(into: []) { $0.insert(.seconds($1)) }
        let sleeps = SleepRecorder(immediate: backoff, limit: 9)
        let m = try await mac("mbp", transport: transport, persistence: persistence, secrets: a.secrets, defaults: a.defaults, sleeps: sleeps)
        m.coordinator.start()
        await eventually("nine sleeps") { sleeps.durations.count == 9 }
        XCTAssertEqual(sleeps.durations, [5, 10, 20, 40, 80, 160, 300, 300, 300].map { .seconds($0) })
        guard case .offline(let message) = m.coordinator.phase else {
            return XCTFail("expected offline, got \(m.coordinator.phase)")
        }
        XCTAssertTrue(message.contains("refused"))
        XCTAssertFalse(message.contains(apiKey))
        m.coordinator.stop()
    }

    func testSuccessAfterOfflineReturnsToTheNormalInterval() async throws {
        let transport = ScriptedTransport()
        let persistence = InMemoryVaultPersistence()
        let a = try await mac("mbp", transport: transport, persistence: persistence)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()

        await transport.fail(2, with: SyncTransportError.unreachable("the request timed out"))
        let sleeps = SleepRecorder(immediate: [.seconds(5), .seconds(10)])
        let m = try await mac("mbp", transport: transport, persistence: persistence, secrets: a.secrets, defaults: a.defaults, sleeps: sleeps)
        m.coordinator.start()
        await eventually("back to interval") { sleeps.durations.count == 3 }
        XCTAssertEqual(sleeps.durations, [.seconds(5), .seconds(10), .seconds(60)])
        XCTAssertEqual(m.coordinator.phase, .idle)
        m.coordinator.stop()
    }

    func testUnauthorizedFailsAndPausesUntilTheUserActs() async throws {
        let transport = ScriptedTransport()
        let persistence = InMemoryVaultPersistence()
        let a = try await mac("mbp", transport: transport, persistence: persistence)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()

        await transport.fail(1, with: SyncTransportError.unauthorized)
        let sleeps = SleepRecorder(immediate: [.seconds(3)])
        let m = try await mac("mbp", transport: transport, persistence: persistence, secrets: a.secrets, defaults: a.defaults, sleeps: sleeps)
        m.coordinator.start()
        await eventually("failed") { m.coordinator.phase == .failed(SyncSetupError.unauthorized.message) }
        try await m.vault.save(Host(label: "nas", address: "nas.lan"))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sleeps.durations, [], "paused: no timer, no debounce")

        await m.coordinator.syncNow()
        XCTAssertEqual(m.coordinator.phase, .idle)
        await eventually("loop resumed") { sleeps.durations == [.seconds(60)] }
        m.coordinator.stop()
    }

    func testTamperedRecordFails() async throws {
        let transport = ScriptedTransport()
        let a = try await mac("mbp", transport: transport)
        let nas = try await a.vault.save(Host(label: "nas", address: "nas.lan"))
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        a.coordinator.stop()
        await transport.server.corruptCiphertext(of: nas.id)

        let b = try await mac("mini", transport: transport)
        try await b.coordinator.connect(serverURL: url, apiKey: apiKey)
        do {
            try await b.coordinator.joinVault(passphrase: passphrase, mode: .merge)
            XCTFail("expected tampered")
        } catch {
            XCTAssertEqual(error, .tampered)
        }
        XCTAssertNil(try b.secrets.loadVaultKey())
    }

    // MARK: Passphrase and disconnect

    func testChangePassphrase() async throws {
        let transport = ScriptedTransport()
        let a = try await mac("mbp", transport: transport)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        do {
            try await a.coordinator.changePassphrase(old: passphrase, new: "short")
            XCTFail("expected weakPassphrase")
        } catch { XCTAssertEqual(error, .weakPassphrase) }
        do {
            try await a.coordinator.changePassphrase(old: "not the passphrase", new: "a brand new passphrase")
            XCTFail("expected wrongPassphrase")
        } catch { XCTAssertEqual(error, .wrongPassphrase) }
        try await a.coordinator.changePassphrase(old: passphrase, new: "a brand new passphrase")
        a.coordinator.stop()

        let b = try await mac("mini", transport: transport)
        try await b.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await b.coordinator.joinVault(passphrase: "a brand new passphrase", mode: .merge)
        XCTAssertEqual(b.coordinator.phase, .idle)
        b.coordinator.stop()
    }

    func testDisconnectForgetsSecretsAndURLButKeepsData() async throws {
        let transport = ScriptedTransport()
        let persistence = InMemoryVaultPersistence()
        let a = try await mac("mbp", transport: transport, persistence: persistence)
        let nas = try await a.vault.save(Host(label: "nas", address: "nas.lan"))
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)

        a.coordinator.disconnect()
        XCTAssertEqual(a.coordinator.phase, .notConfigured)
        XCTAssertNil(a.coordinator.serverURL)
        XCTAssertNil(a.coordinator.lastSyncedAt)
        XCTAssertNil(try a.secrets.loadVaultKey())
        XCTAssertNil(try a.secrets.loadAPIKey())
        XCTAssertNil(a.defaults.string(forKey: "sync.serverURL"))
        XCTAssertEqual(a.vault.get(Host.self, id: nas.id)?.label, "nas")
        await a.vault.flush()
        let state = await persistence.contents?.syncState
        XCTAssertEqual(state, SyncState(vaultID: nil, lastSeq: 0))
    }

    func testDisconnectDuringASyncIgnoresItsResult() async throws {
        let transport = ScriptedTransport()
        let a = try await mac("mbp", transport: transport)
        try await a.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await a.coordinator.createVault(passphrase: passphrase)
        try await a.vault.save(Host(label: "nas", address: "nas.lan"))
        let coordinator = a.coordinator
        await transport.server.onNextUpsert { await MainActor.run { coordinator.disconnect() } }
        await a.coordinator.syncNow()
        XCTAssertEqual(a.coordinator.phase, .notConfigured)
        XCTAssertNil(a.coordinator.lastSyncedAt)
        XCTAssertNil(a.coordinator.lastReport)
    }

    // MARK: Keychain failures

    private func flakyMac(_ device: String, transport: ScriptedTransport, persistence: InMemoryVaultPersistence,
                          secrets: FlakySecrets, defaults: UserDefaults) async throws -> SyncCoordinator {
        let vault = try await LocalVault.open(persistence: persistence, newDeviceID: { device })
        let sleeps = SleepRecorder()
        return SyncCoordinator(vault: vault, secrets: secrets, defaults: defaults,
                               makeTransport: { _, _ in transport }, iterations: 1_000,
                               sleep: { try await sleeps.sleep($0) }, now: { Date(timeIntervalSince1970: 5_000) })
    }

    func testKeychainReadFailureAtStartFailsWithARetryPath() async throws {
        let transport = ScriptedTransport()
        let persistence = InMemoryVaultPersistence()
        let secrets = FlakySecrets()
        let defaults = defaults()
        let first = try await flakyMac("mbp", transport: transport, persistence: persistence, secrets: secrets,
                                       defaults: defaults)
        try await first.connect(serverURL: url, apiKey: apiKey)
        try await first.createVault(passphrase: passphrase)
        first.stop()

        secrets.failReads = true
        let relaunched = try await flakyMac("mbp", transport: transport, persistence: persistence, secrets: secrets,
                                            defaults: defaults)
        relaunched.start()
        let message = "Couldn't read the sync keys from the Keychain. Open Settings → Sync and try again."
        XCTAssertEqual(relaunched.phase, .failed(message))
        XCTAssertEqual(SyncSetupError.keychainUnreadable.message, message)
        await relaunched.syncNow()
        XCTAssertEqual(relaunched.phase, .failed(message), "still unreadable")

        secrets.failReads = false
        await relaunched.syncNow()
        XCTAssertEqual(relaunched.phase, .idle, "Sync now retries reading the keys, no passphrase needed")
        relaunched.stop()

        secrets.failReads = true
        let again = try await flakyMac("mbp", transport: transport, persistence: persistence, secrets: secrets,
                                       defaults: defaults)
        again.start()
        XCTAssertEqual(again.phase, .failed(message))
        secrets.failReads = false
        again.start()
        await eventually("start() retries too") { again.phase == .idle }
        again.stop()
    }

    func testDisconnectSurfacesAKeychainDeleteFailure() async throws {
        let transport = ScriptedTransport()
        let secrets = FlakySecrets()
        let coordinator = try await flakyMac("mbp", transport: transport, persistence: InMemoryVaultPersistence(),
                                             secrets: secrets, defaults: defaults())
        try await coordinator.connect(serverURL: url, apiKey: apiKey)
        XCTAssertNil(coordinator.lastError)
        secrets.failDelete = true
        coordinator.disconnect()
        XCTAssertEqual(coordinator.lastError, .keychainCleanupFailed)
        XCTAssertFalse(SyncSetupError.keychainCleanupFailed.message.isEmpty)
        XCTAssertEqual(coordinator.phase, .notConfigured)

        secrets.failDelete = false
        try await coordinator.connect(serverURL: url, apiKey: apiKey)
        XCTAssertNil(coordinator.lastError, "a later successful action clears it")
        coordinator.disconnect()
        XCTAssertNil(coordinator.lastError)
        XCTAssertNil(try secrets.base.loadAPIKey())
    }

    // MARK: Vault missing during a normal sync

    private func syncingMac(_ transport: ScriptedTransport) async throws -> Mac {
        let m = try await mac("mbp", transport: transport)
        try await m.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await m.coordinator.createVault(passphrase: passphrase)
        XCTAssertEqual(m.coordinator.phase, .idle)
        return m
    }

    func testVaultNotFoundWithHealthyServerFailsWithAddressHint() async throws {
        let transport = ScriptedTransport()
        let m = try await syncingMac(transport)
        await transport.server.replaceVault(nil)
        await m.coordinator.syncNow()
        let message = "The sync server answered but has no vault at this address. Check the server address "
            + "(proxy path) — or, if the server was reset, disconnect and set up sync again."
        XCTAssertEqual(SyncSetupError.noVaultAtAddress.message, message)
        XCTAssertEqual(m.coordinator.phase, .failed(message))
        m.coordinator.stop()
    }

    func testVaultNotFoundWithFailingHealthIsOffline() async throws {
        let transport = ScriptedTransport()
        let m = try await syncingMac(transport)
        await transport.server.replaceVault(nil)
        await transport.failHealth(SyncTransportError.http(status: 502, message: ""))
        await m.coordinator.syncNow()
        guard case .offline = m.coordinator.phase else {
            return XCTFail("expected offline, got \(m.coordinator.phase)")
        }
        m.coordinator.stop()
    }

    func testReplacedVaultStillSaysReplaced() async throws {
        let transport = ScriptedTransport()
        let m = try await syncingMac(transport)
        await transport.server.replaceVault(VaultMetadata(vaultID: UUID(), salt: Data(count: 16), iterations: 1_000,
                                                          wrappedKey: Data(count: 60)))
        await m.coordinator.syncNow()
        XCTAssertEqual(m.coordinator.phase, .failed(SyncSetupError.vaultChanged.message))
        m.coordinator.stop()
    }

    // MARK: Updating the API key

    private func rotatingMac(_ transport: ScriptedTransport, valid: ValidKeys, sleeps: SleepRecorder = SleepRecorder())
        async throws -> (coordinator: SyncCoordinator, vault: LocalVault, secrets: InMemorySyncSecretsStore) {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "mbp" })
        let secrets = InMemorySyncSecretsStore()
        let coordinator = SyncCoordinator(vault: vault, secrets: secrets, defaults: defaults(),
                                          makeTransport: { _, key in KeyCheckingTransport(base: transport, apiKey: key, valid: valid) },
                                          iterations: 1_000, sleep: { try await sleeps.sleep($0) },
                                          now: { Date(timeIntervalSince1970: 5_000) })
        return (coordinator, vault, secrets)
    }

    func testUpdateAPIKeyResumesSyncingWithoutThePassphrase() async throws {
        let transport = ScriptedTransport()
        let valid = ValidKeys([apiKey])
        let sleeps = SleepRecorder()
        let m = try await rotatingMac(transport, valid: valid, sleeps: sleeps)
        try await m.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await m.coordinator.createVault(passphrase: passphrase)

        valid.set(["rotated-key-7890"])
        let host = try await m.vault.save(Host(label: "nas", address: "nas.lan"))
        await m.coordinator.syncNow()
        XCTAssertEqual(m.coordinator.phase, .failed(SyncSetupError.unauthorized.message))

        do {
            try await m.coordinator.updateAPIKey("still-wrong-key")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(try m.secrets.loadAPIKey(), apiKey, "a rejected key isn't saved")

        try await m.coordinator.updateAPIKey("rotated-key-7890")
        XCTAssertEqual(try m.secrets.loadAPIKey(), "rotated-key-7890")
        XCTAssertEqual(m.coordinator.phase, .idle)
        let stored = await transport.server.storedRecords.map(\.id)
        XCTAssertTrue(stored.contains(host.id), "the pending edit was pushed with the new key")
        await eventually("loop resumed") { sleeps.durations.contains(.seconds(60)) }
        m.coordinator.stop()
    }

    func testUpdateAPIKeyWithoutAVaultKeyKeepsAskingForTheVault() async throws {
        let transport = ScriptedTransport()
        let valid = ValidKeys([apiKey, "new-key-123456"])
        let m = try await rotatingMac(transport, valid: valid)
        do {
            try await m.coordinator.updateAPIKey("new-key-123456")
            XCTFail("expected an error before connecting")
        } catch {
            XCTAssertEqual(error, .other("Connect to a sync server first."))
        }
        try await m.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await m.coordinator.updateAPIKey("new-key-123456")
        XCTAssertEqual(m.coordinator.phase, .needsVault(exists: false))
        XCTAssertEqual(try m.secrets.loadAPIKey(), "new-key-123456")
        try await m.coordinator.createVault(passphrase: passphrase)
        XCTAssertEqual(m.coordinator.phase, .idle)
        m.coordinator.stop()
    }

    // MARK: lastSyncedAt

    func testLastSyncedAtIsPersistedAndRestoredAtInit() async throws {
        let transport = ScriptedTransport()
        let m = try await syncingMac(transport)
        m.coordinator.stop()
        XCTAssertEqual(m.coordinator.lastSyncedAt, Date(timeIntervalSince1970: 5_000))
        let relaunched = try await mac("mbp", transport: transport, secrets: m.secrets, defaults: m.defaults)
        XCTAssertEqual(relaunched.coordinator.lastSyncedAt, Date(timeIntervalSince1970: 5_000))
        relaunched.coordinator.disconnect()
        XCTAssertNil(m.defaults.object(forKey: "sync.lastSyncedAt"))
        let afterDisconnect = try await mac("mbp", transport: transport, defaults: m.defaults)
        XCTAssertNil(afterDisconnect.coordinator.lastSyncedAt)
    }

    // MARK: End to end: MacBook creates, Mac mini merges

    func testMacBookCreatesMacMiniMergesWithoutDuplicates() async throws {
        let transport = ScriptedTransport()
        let macBook = try await mac("MacBook", transport: transport)
        let key = try await macBook.vault.save(SSHKey(label: "main", keyType: .ed25519,
                                                      publicKey: "ssh-ed25519 AAAAKEY cory@macbook", privateKey: "pk"))
        let identity = try await macBook.vault.save(Identity(label: "Home", username: "cory", sshKeyID: key.id))
        let nas = try await macBook.vault.save(Host(label: "NAS", address: "nas.lan", username: "cory",
                                                    identityID: identity.id))
        try await macBook.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await macBook.coordinator.createVault(passphrase: passphrase)

        let mini = try await mac("Mac mini", transport: transport)
        let miniKey = try await mini.vault.save(SSHKey(label: "mine", keyType: .ed25519,
                                                       publicKey: "ssh-ed25519 AAAAKEY cory@mini", privateKey: "pk"))
        let miniIdentity = try await mini.vault.save(Identity(label: "Home", username: "cory", sshKeyID: miniKey.id))
        let miniNAS = try await mini.vault.save(Host(label: "nas (mini)", address: "NAS.lan", port: 22,
                                                     username: "cory", identityID: miniIdentity.id))
        let pi = try await mini.vault.save(Host(label: "pi", address: "pi.lan", identityID: miniIdentity.id,
                                                sshKeyID: miniKey.id))
        let log = try await mini.vault.save(ConnectionLog(hostID: miniNAS.id, hostLabel: "nas", username: "cory",
                                                          deviceName: "Mac mini"))
        try await mini.coordinator.connect(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(mini.coordinator.phase, .needsVault(exists: true))
        try await mini.coordinator.joinVault(passphrase: passphrase, mode: .merge)

        // No duplicates on the Mac mini, references re-pointed.
        XCTAssertEqual(Set(mini.vault.all(Host.self).map(\.id)), [nas.id, pi.id])
        XCTAssertEqual(mini.vault.all(Identity.self).map(\.id), [identity.id])
        XCTAssertEqual(mini.vault.all(SSHKey.self).map(\.id), [key.id])
        XCTAssertEqual(mini.vault.get(Host.self, id: pi.id)?.identityID, identity.id)
        XCTAssertEqual(mini.vault.get(Host.self, id: pi.id)?.sshKeyID, key.id)
        XCTAssertEqual(mini.vault.get(ConnectionLog.self, id: log.id)?.hostID, nas.id)
        // No tombstones for the dropped duplicates were uploaded.
        let storedIDs = Set(await transport.server.storedRecords.map(\.id))
        XCTAssertFalse(storedIDs.contains(miniNAS.id))
        XCTAssertFalse(storedIDs.contains(miniIdentity.id))
        XCTAssertFalse(storedIDs.contains(miniKey.id))

        // The MacBook gets the Mac mini's additions.
        await macBook.coordinator.syncNow()
        XCTAssertEqual(Set(macBook.vault.all(Host.self).map(\.id)), [nas.id, pi.id])
        XCTAssertEqual(macBook.vault.all(Identity.self).count, 1)
        XCTAssertEqual(macBook.vault.get(ConnectionLog.self, id: log.id)?.hostID, nas.id)

        // Edits flow both ways.
        var renamed = try XCTUnwrap(macBook.vault.get(Host.self, id: nas.id))
        renamed.label = "Synology"
        try await macBook.vault.save(renamed)
        await macBook.coordinator.syncNow()
        await mini.coordinator.syncNow()
        XCTAssertEqual(mini.vault.get(Host.self, id: nas.id)?.label, "Synology")

        var piEdit = try XCTUnwrap(mini.vault.get(Host.self, id: pi.id))
        piEdit.port = 2222
        try await mini.vault.save(piEdit)
        await mini.coordinator.syncNow()
        await macBook.coordinator.syncNow()
        XCTAssertEqual(macBook.vault.get(Host.self, id: pi.id)?.port, 2222)

        // Deletes propagate.
        try await mini.vault.deleteSSHKey(id: key.id)
        await mini.coordinator.syncNow()
        await macBook.coordinator.syncNow()
        XCTAssertNil(macBook.vault.get(SSHKey.self, id: key.id))
        XCTAssertNil(macBook.vault.get(Host.self, id: pi.id)?.sshKeyID)
        XCTAssertNil(macBook.vault.get(Identity.self, id: identity.id)?.sshKeyID)

        XCTAssertEqual(macBook.coordinator.phase, .idle)
        XCTAssertEqual(mini.coordinator.phase, .idle)
        macBook.coordinator.stop()
        mini.coordinator.stop()
    }
}

private final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (URL, String)?
    var value: (URL, String)? { lock.withLock { _value } }
    func set(_ url: URL, _ key: String) { lock.withLock { _value = (url, key) } }
}

/// An `InMemorySyncSecretsStore` whose reads or deleteAll can be made to fail (a locked Keychain).
private final class FlakySecrets: SyncSecretsStore, @unchecked Sendable {
    struct KeychainError: Error {}
    let base = InMemorySyncSecretsStore()
    private let lock = NSLock()
    private var _failReads = false
    private var _failDelete = false
    var failReads: Bool {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }
    var failDelete: Bool {
        get { lock.withLock { _failDelete } }
        set { lock.withLock { _failDelete = newValue } }
    }

    func loadVaultKey() throws -> VaultKey? {
        if failReads { throw KeychainError() }
        return try base.loadVaultKey()
    }
    func saveVaultKey(_ key: VaultKey) throws { try base.saveVaultKey(key) }
    func loadAPIKey() throws -> String? {
        if failReads { throw KeychainError() }
        return try base.loadAPIKey()
    }
    func saveAPIKey(_ key: String) throws { try base.saveAPIKey(key) }
    func deleteAll() throws {
        if failDelete { throw KeychainError() }
        try base.deleteAll()
    }
}

/// The server's API keys, changeable at runtime (key rotation).
private final class ValidKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String>
    init(_ keys: Set<String>) { self.keys = keys }
    func set(_ keys: Set<String>) { lock.withLock { self.keys = keys } }
    func accepts(_ key: String) -> Bool { lock.withLock { keys.contains(key) } }
}

/// Forwards to `ScriptedTransport` while `apiKey` is valid; otherwise every authenticated call is
/// `.unauthorized` (health needs no key).
private struct KeyCheckingTransport: SyncTransport {
    let base: ScriptedTransport
    let apiKey: String
    let valid: ValidKeys

    private func check() throws {
        if !valid.accepts(apiKey) { throw SyncTransportError.unauthorized }
    }
    func health() async throws { try await base.health() }
    func getVault() async throws -> VaultMetadata? { try check(); return try await base.getVault() }
    func putVault(_ metadata: VaultMetadata) async throws { try check(); try await base.putVault(metadata) }
    func rewrap(_ request: RewrapRequest) async throws -> VaultMetadata { try check(); return try await base.rewrap(request) }
    func fetch(since: Int64, limit: Int) async throws -> RecordsPage {
        try check()
        return try await base.fetch(since: since, limit: limit)
    }
    func upsert(_ records: [EncryptedRecord]) async throws -> [EncryptedRecord] {
        try check()
        return try await base.upsert(records)
    }
}
