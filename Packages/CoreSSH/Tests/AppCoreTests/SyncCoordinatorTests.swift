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

    func health() async throws {
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
    func fetch(since: Int64, limit: Int) async throws -> RecordsPage { try await server.fetch(since: since, limit: limit) }
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
