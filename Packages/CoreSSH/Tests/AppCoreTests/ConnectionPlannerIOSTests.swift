import XCTest
import CoreModels
import SSHCore
import SyncCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// iPhone/iPad routing: the built-in engine only, imported keys for 1Password hosts, no RSA.
@MainActor
final class ConnectionPlannerIOSTests: XCTestCase {
    private func makeVault() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    private func candidate(_ n: Int, type: KeyType = .ed25519) -> SSHKeyCandidate {
        SSHKeyCandidate(type: type, pem: "PEM-\(n)", label: "key \(n)", publicKey: "ssh-ed25519 PUB\(n)")
    }

    private func pems(_ plan: ConnectionPlan) -> [String]? {
        guard case .privateKeys(let keys) = plan.credential else { return nil }
        return keys.map(\.pem)
    }

    func testBackupAddressGoesIntoTheIOSPlan() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "H", address: "nas.lan", fallbackAddress: "nas.tail1234.ts.net",
                                                  username: "root", password: "pw"))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios, importedKeys: [])
        XCTAssertEqual(plan.host, "nas.lan")
        XCTAssertEqual(plan.fallbackHost, "nas.tail1234.ts.net")
    }

    func testPinnedAgentKeyIsOfferedFirst() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "H", address: "h", username: "root",
                                                  agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 PUB3 me@mac")))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios,
                                              importedKeys: [candidate(1), candidate(2), candidate(3)])
        XCTAssertEqual(pems(plan), ["PEM-3", "PEM-1", "PEM-2"])
        XCTAssertEqual(plan.engine, .citadel)
        XCTAssertNil(plan.agentKey, "no agent on iOS: the session manager must not look for a socket")
    }

    func testUnpinnedAgentKeyOffersAtMostFiveImportedKeys() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "alice", agentKey: AgentKeyChoice(publicKey: nil)))
        let host = try await vault.save(SavedHost(label: "H", address: "h", identityID: identity.id))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios,
                                              importedKeys: (1...7).map { candidate($0) })
        XCTAssertEqual(pems(plan), ["PEM-1", "PEM-2", "PEM-3", "PEM-4", "PEM-5"])
        XCTAssertEqual(plan.username, "alice")
    }

    func testPinnedKeyBeyondTheFirstFiveIsStillOffered() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "H", address: "h", username: "root",
                                                  agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 PUB7")))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios,
                                              importedKeys: (1...7).map { candidate($0) })
        XCTAssertEqual(pems(plan), ["PEM-7", "PEM-1", "PEM-2", "PEM-3", "PEM-4"])
    }

    func testImportedRSAKeysAreNeverOffered() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "H", address: "h", username: "root",
                                                  agentKey: AgentKeyChoice(publicKey: nil)))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios,
                                              importedKeys: [candidate(1, type: .rsa), candidate(2)])
        XCTAssertEqual(pems(plan), ["PEM-2"])
    }

    func testAgentHostWithoutImportedKeysThrows() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "Web", address: "h", username: "root",
                                                  agentKey: AgentKeyChoice(publicKey: nil)))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios, importedKeys: [])) {
            XCTAssertEqual($0 as? ConnectionPlanError, .noImportedKeys(hostLabel: "Web"))
        }
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios,
                                                        importedKeys: [candidate(1, type: .rsa)])) {
            XCTAssertEqual($0 as? ConnectionPlanError, .noImportedKeys(hostLabel: "Web"))
        }
        let message = ConnectionPlanError.noImportedKeys(hostLabel: "Web").errorDescription ?? ""
        XCTAssertTrue(message.contains("Web"), message)
        XCTAssertTrue(message.contains("Import"), message)
    }

    func testRSAKeyHostThrowsOnIOS() async throws {
        let vault = try await makeVault()
        let key = try await vault.save(SSHKey(label: "k", keyType: .rsa, publicKey: "pub", privateKey: "PEM-rsa"))
        let host = try await vault.save(SavedHost(label: "Old", address: "h", username: "root", sshKeyID: key.id))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios, importedKeys: [])) {
            XCTAssertEqual($0 as? ConnectionPlanError, .rsaUnsupported(hostLabel: "Old"))
        }
        XCTAssertEqual(ConnectionPlanError.rsaUnsupported(hostLabel: "Old").errorDescription,
                       "RSA keys aren't supported on iPhone/iPad yet; use an Ed25519 key.")
    }

    func testUseSystemSSHIsIgnoredOnIOS() async throws {
        let vault = try await makeVault()
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "PEM-ed"))
        let host = try await vault.save(SavedHost(label: "H", address: "h", username: "root", password: "pw",
                                                  useSystemSSH: true))
        let keyed = try await vault.save(SavedHost(label: "K", address: "k", username: "root", sshKeyID: key.id,
                                                   useSystemSSH: true))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios, importedKeys: [])
        XCTAssertEqual(plan.engine, .citadel)
        guard case .password("pw") = plan.credential else { return XCTFail("\(plan.credential)") }
        let keyedPlan = try ConnectionPlanner.plan(hostID: keyed.id, vault: vault, platform: .ios, importedKeys: [])
        XCTAssertEqual(keyedPlan.engine, .citadel)
        guard case .privateKey(.ed25519, "PEM-ed", nil) = keyedPlan.credential else { return XCTFail("\(keyedPlan.credential)") }
    }

    func testMacPlansAreUnchanged() async throws {
        let vault = try await makeVault()
        let rsa = try await vault.save(SSHKey(label: "k", keyType: .rsa, publicKey: "pub", privateKey: "PEM-rsa"))
        let rsaHost = try await vault.save(SavedHost(label: "R", address: "r", username: "root", sshKeyID: rsa.id))
        let choice = AgentKeyChoice(publicKey: "ssh-ed25519 PUB1")
        let agentHost = try await vault.save(SavedHost(label: "A", address: "a", username: "root", agentKey: choice))
        for (id, engine) in [(rsaHost.id, SSHEngine.systemSSH), (agentHost.id, .systemSSH)] {
            let old = try ConnectionPlanner.plan(hostID: id, vault: vault)
            let mac = try ConnectionPlanner.plan(hostID: id, vault: vault, platform: .mac, importedKeys: [candidate(1)])
            XCTAssertEqual(old.engine, engine)
            XCTAssertEqual(mac.engine, engine)
            XCTAssertEqual(mac.agentKey, old.agentKey)
            XCTAssertEqual(mac.credential.description, old.credential.description)
        }
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: agentHost.id, vault: vault, platform: .mac, importedKeys: []).agentKey,
                       choice)
    }

    func testKeyCandidatesNeverPrintKeyMaterial() async {
        let secret = "-----BEGIN OPENSSH PRIVATE KEY-----\nSECRETSECRET\n-----END OPENSSH PRIVATE KEY-----"
        let c = SSHKeyCandidate(type: .ed25519, pem: secret, label: "laptop", publicKey: "ssh-ed25519 PUBLICBLOB")
        let credential = SSHCredential.privateKeys([c, c])
        for text in [c.description, String(reflecting: c), credential.description, credential.debugDescription,
                     "\(credential)", String(reflecting: credential)] {
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertFalse(text.contains("PUBLICBLOB"), text)
        }
    }
    // MARK: 1Password references (no op CLI on iOS)

    func testOnePasswordPasswordIsAskedForOnIOS() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "Web", address: "h", username: "root",
                                                  password: "op://Private/Web/password"))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios, importedKeys: [])
        guard case .none = plan.credential else { return XCTFail("\(plan.credential)") }
        let mac = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        guard case .password("op://Private/Web/password") = mac.credential else { return XCTFail("\(mac.credential)") }
    }

    func testKeyWithAOnePasswordPassphraseThrowsOnIOS() async throws {
        let vault = try await makeVault()
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "PEM-ed",
                                              passphrase: " op://Private/Key/passphrase"))
        let host = try await vault.save(SavedHost(label: "Box", address: "h", username: "root", sshKeyID: key.id))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: host.id, vault: vault, platform: .ios, importedKeys: [])) {
            XCTAssertEqual($0 as? ConnectionPlanError, .passphraseInOnePassword(hostLabel: "Box"))
        }
        let message = ConnectionPlanError.passphraseInOnePassword(hostLabel: "Box").errorDescription ?? ""
        XCTAssertTrue(message.contains("Box"), message)
        XCTAssertFalse(message.contains("op://"), message)
    }

    func testLockedKeysErrorExplainsWhatToDo() async {
        let message = ConnectionPlanError.importedKeysLocked(hostLabel: "Pi").errorDescription ?? ""
        XCTAssertTrue(message.contains("Face ID"), message)
        XCTAssertTrue(message.contains("Start Over"), message)
    }
}
