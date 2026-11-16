import XCTest
import CoreModels
import SyncCore
import SyncTestSupport
@testable import AppCore

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

@MainActor
final class CompanionJoinTests: XCTestCase {
    private let url = URL(string: "https://proxy.example/sync/")!
    private let apiKey = "api-key-123456"
    private let passphrase = "correct horse battery"
    private var suites: [String] = []
    private var coordinators: [SyncCoordinator] = []

    override func tearDown() async throws {
        for coordinator in coordinators { coordinator.stop() }
        coordinators = []
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }

    private struct Device {
        let vault: LocalVault
        let secrets: InMemorySyncSecretsStore
        let coordinator: SyncCoordinator
    }

    private func device(_ name: String, transport: ScriptedTransport) async throws -> Device {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { name })
        let suite = "companion-join-tests-\(UUID().uuidString)"
        suites.append(suite)
        let secrets = InMemorySyncSecretsStore()
        let sleeps = SleepRecorder()
        let coordinator = SyncCoordinator(vault: vault, secrets: secrets, defaults: UserDefaults(suiteName: suite)!,
                                          makeTransport: { _, _ in transport }, iterations: 1_000,
                                          sleep: { try await sleeps.sleep($0) })
        coordinators.append(coordinator)
        return Device(vault: vault, secrets: secrets, coordinator: coordinator)
    }

    /// A server whose vault a Mac created, holding one host.
    private func serverWithAVault() async throws -> (ScriptedTransport, Host) {
        let transport = ScriptedTransport()
        let mac = try await device("mac", transport: transport)
        let host = try await mac.vault.save(Host(label: "nas", address: "nas.lan"))
        try await mac.coordinator.connect(serverURL: url, apiKey: apiKey)
        try await mac.coordinator.createVault(passphrase: passphrase)
        mac.coordinator.stop()
        return (transport, host)
    }

    private func fill(_ form: CompanionJoin, passphrase: String? = nil) {
        form.serverAddress = " \(url.absoluteString) "
        form.apiKey = " \(apiKey)\n"
        form.passphrase = passphrase ?? self.passphrase
    }

    func testJoinPullsTheVaultAndClearsTheSecrets() async throws {
        let (transport, host) = try await serverWithAVault()
        let phone = try await device("phone", transport: transport)
        let form = CompanionJoin(coordinator: phone.coordinator)
        XCTAssertFalse(CompanionJoin.isJoined(phone.coordinator.phase))
        fill(form)
        XCTAssertTrue(form.canJoin)

        let joined = await form.join()

        XCTAssertTrue(joined)
        XCTAssertNil(form.errorMessage)
        XCTAssertEqual(phone.vault.all(Host.self).map(\.id), [host.id])
        XCTAssertTrue(CompanionJoin.isJoined(phone.coordinator.phase))
        XCTAssertEqual(try phone.secrets.loadAPIKey(), apiKey)
        XCTAssertNotNil(try phone.secrets.loadVaultKey())
        XCTAssertEqual(form.apiKey, "")
        XCTAssertEqual(form.passphrase, "")
        XCTAssertFalse(form.isJoining)
    }

    func testWrongPassphraseSaysSoAndStaysUnjoined() async throws {
        let (transport, _) = try await serverWithAVault()
        let phone = try await device("phone", transport: transport)
        let form = CompanionJoin(coordinator: phone.coordinator)
        fill(form, passphrase: "not the passphrase")

        let joined = await form.join()

        XCTAssertFalse(joined)
        XCTAssertEqual(form.errorMessage, SyncSetupError.wrongPassphrase.message)
        XCTAssertFalse(CompanionJoin.isJoined(phone.coordinator.phase))
        XCTAssertNil(try phone.secrets.loadVaultKey())
        XCTAssertEqual(form.passphrase, "not the passphrase", "kept so it can be corrected")
    }

    func testServerWithoutAVaultAsksToSetUpTheMacFirst() async throws {
        let transport = ScriptedTransport()
        let phone = try await device("phone", transport: transport)
        let form = CompanionJoin(coordinator: phone.coordinator)
        fill(form)

        let joined = await form.join()

        XCTAssertFalse(joined)
        XCTAssertEqual(form.errorMessage, CompanionJoin.noVaultMessage)
        let vault = try await transport.server.getVault()
        XCTAssertNil(vault, "the phone never creates a vault")
        XCTAssertFalse(CompanionJoin.isJoined(phone.coordinator.phase))
    }

    func testInvalidAddressIsReportedWithoutContactingTheServer() async throws {
        let transport = ScriptedTransport()
        let phone = try await device("phone", transport: transport)
        let form = CompanionJoin(coordinator: phone.coordinator)
        fill(form)
        form.serverAddress = "proxy.example"

        let joined = await form.join()

        XCTAssertFalse(joined)
        XCTAssertEqual(form.errorMessage, SyncSetupError.invalidURL.message)
        XCTAssertNil(phone.coordinator.serverURL)
        let attempts = await transport.syncAttempts
        XCTAssertEqual(attempts, 0)
    }

    func testRejectedAPIKeyIsReported() async throws {
        let (transport, _) = try await serverWithAVault()
        await transport.failAlways(SyncTransportError.unauthorized)
        let phone = try await device("phone", transport: transport)
        let form = CompanionJoin(coordinator: phone.coordinator)
        fill(form)

        let joined = await form.join()

        XCTAssertFalse(joined)
        XCTAssertEqual(form.errorMessage, SyncSetupError.unauthorized.message)
        XCTAssertNil(try phone.secrets.loadAPIKey())
    }

    func testCanJoinNeedsEveryField() async throws {
        let phone = try await device("phone", transport: ScriptedTransport())
        let form = CompanionJoin(coordinator: phone.coordinator)
        XCTAssertFalse(form.canJoin)
        fill(form)
        form.apiKey = "  "
        XCTAssertFalse(form.canJoin)
        fill(form)
        form.passphrase = ""
        XCTAssertFalse(form.canJoin)
        let joined = await form.join()
        XCTAssertFalse(joined)
        XCTAssertNil(form.errorMessage)
    }

    func testFormStartsWithTheSavedServerAddress() async throws {
        let (transport, _) = try await serverWithAVault()
        let phone = try await device("phone", transport: transport)
        try await phone.coordinator.connect(serverURL: url, apiKey: apiKey)
        XCTAssertEqual(CompanionJoin(coordinator: phone.coordinator).serverAddress, url.absoluteString)
    }

    func testJoinedPhases() async {
        XCTAssertFalse(CompanionJoin.isJoined(.notConfigured))
        XCTAssertFalse(CompanionJoin.isJoined(.needsVault(exists: true)))
        XCTAssertFalse(CompanionJoin.isJoined(.locked))
        XCTAssertTrue(CompanionJoin.isJoined(.idle))
        XCTAssertTrue(CompanionJoin.isJoined(.syncing))
        XCTAssertTrue(CompanionJoin.isJoined(.offline("down")))
        XCTAssertTrue(CompanionJoin.isJoined(.failed("tampered")))
    }
    // MARK: Leave sync

    func testLeavingForgetsSyncEmptiesTheVaultAndDeletesTheKeys() async throws {
        let (transport, host) = try await serverWithAVault()
        let phone = try await device("phone", transport: transport)
        let form = CompanionJoin(coordinator: phone.coordinator)
        fill(form)
        let joined = await form.join()
        XCTAssertTrue(joined)
        _ = try await phone.vault.save(KnownHost(hostPort: "nas.lan:22", keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:x"))
        let library = ImportedKeyLibrary(storage: InMemoryImportedKeyStorage())
        try library.importKey(text: KeyFixtures.plainEd25519, name: nil, passphrase: nil)

        try await form.leave(vault: phone.vault, keys: library)

        XCTAssertEqual(phone.coordinator.phase, .notConfigured)
        XCTAssertFalse(CompanionJoin.isJoined(phone.coordinator.phase))
        XCTAssertTrue(phone.vault.all(Host.self).isEmpty)
        XCTAssertTrue(phone.vault.all(KnownHost.self).isEmpty)
        XCTAssertNil(try phone.secrets.loadAPIKey())
        XCTAssertNil(try phone.secrets.loadVaultKey())
        XCTAssertTrue(library.keys.isEmpty)
        XCTAssertEqual(form.serverAddress, url.absoluteString, "the address stays filled in for joining again")

        // Joining again (e.g. after "vault changed") brings the hosts back.
        fill(form)
        let rejoined = await form.join()
        XCTAssertTrue(rejoined)
        XCTAssertEqual(phone.vault.all(Host.self).map(\.id), [host.id])
    }
}
