import XCTest
import CoreModels
import SyncCore
@testable import AppCore

@MainActor
final class KeychainViewModelTests: XCTestCase {
    private func makeVault() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    func testNewIdentityAppearsSorted() async throws {
        let vault = try await makeVault()
        _ = try await vault.save(Identity(label: "Zed", username: "z"))
        _ = try await vault.save(Identity(label: "alpha", username: "a"))
        let vm = KeychainViewModel(vault: vault)
        let created = try await vm.newIdentity()
        XCTAssertEqual(created.label, "New identity")
        XCTAssertEqual(vm.identities.map(\.label), ["alpha", "New identity", "Zed"])
    }

    func testUsageSummaryCountsDirectAndGroupDefaultUse() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        let identity = try await vault.save(Identity(label: "i", username: "u"))
        XCTAssertEqual(vm.usageSummary(identityID: identity.id), "Not used")
        let parent = try await vault.save(HostGroup(name: "p", defaultIdentityID: identity.id))
        let child = try await vault.save(HostGroup(name: "c", parentID: parent.id))
        _ = try await vault.save(SavedHost(label: "direct", address: "a", identityID: identity.id))
        XCTAssertEqual(vm.usageSummary(identityID: identity.id), "Used by 1 host")
        _ = try await vault.save(SavedHost(label: "inherit", address: "b", groupID: child.id))
        _ = try await vault.save(SavedHost(label: "own creds", address: "c", groupID: child.id, username: "root"))
        let ownKey = try await vault.save(SSHKey(label: "own", keyType: .ed25519, publicKey: "p", privateKey: "k"))
        _ = try await vault.save(SavedHost(label: "own key", address: "d", groupID: parent.id, sshKeyID: ownKey.id))
        _ = try await vault.save(SavedHost(label: "both", address: "e", groupID: parent.id, identityID: identity.id))
        XCTAssertEqual(vm.usageSummary(identityID: identity.id), "Used by 3 hosts")
    }

    func testDeadExplicitIdentityCountsTowardGroupDefault() async throws {
        let vault = try await makeVault()
        let gone = try await vault.save(Identity(label: "gone", username: "g"))
        let def = try await vault.save(Identity(label: "D", username: "d"))
        let group = try await vault.save(HostGroup(name: "g", defaultIdentityID: def.id))
        _ = try await vault.save(SavedHost(label: "H", address: "a", groupID: group.id, identityID: gone.id))
        try await vault.delete(Identity.self, id: gone.id)
        let vm = KeychainViewModel(vault: vault)
        XCTAssertEqual(vm.usageCount(identityID: def.id), 1)
        XCTAssertEqual(vm.usageCount(identityID: gone.id), 0)
    }

    func testExplicitIdentityHostDoesNotCountTowardItsDirectKey() async throws {
        let vault = try await makeVault()
        let direct = try await vault.save(SSHKey(label: "direct", keyType: .ed25519, publicKey: "p", privateKey: "k"))
        let viaIdentity = try await vault.save(SSHKey(label: "viaID", keyType: .ed25519, publicKey: "p", privateKey: "k"))
        let identity = try await vault.save(Identity(label: "i", username: "u", sshKeyID: viaIdentity.id))
        _ = try await vault.save(SavedHost(label: "H", address: "a", identityID: identity.id, sshKeyID: direct.id))
        let vm = KeychainViewModel(vault: vault)
        XCTAssertEqual(vm.usageCount(identityID: identity.id), 1)
        XCTAssertEqual(vm.usageCount(sshKeyID: viaIdentity.id), 1)
        XCTAssertEqual(vm.usageCount(sshKeyID: direct.id), 0)
    }

    func testGenerateEd25519StoresKeyWithPublicKey() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        let key = try await vm.generateKey(label: "my\nkey\t", type: .ed25519)
        XCTAssertEqual(key.label, "my\nkey\t")
        XCTAssertEqual(key.keyType, .ed25519)
        XCTAssertTrue(key.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(key.publicKey.hasSuffix(" my key"))
        XCTAssertEqual(vm.publicKeyForCopy(sshKeyID: key.id), key.publicKey)
        XCTAssertEqual(vm.keys.map(\.id), [key.id])
        let empty = try await vm.generateKey(label: "  ", type: .ed25519)
        XCTAssertEqual(empty.publicKey.split(separator: " ").count, 2)
        XCTAssertFalse(empty.publicKey.hasSuffix(" "))
    }

    func testImportEncryptedOpenSSHKeepsPassphraseAndPublicKey() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        let generated = SSHKeyGenerator.ed25519(comment: "c")
        // Encrypted PEM: public key is unknown to the importer, so the explicit one wins.
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,00112233445566778899AABBCCDDEEFF

        AAAA
        -----END RSA PRIVATE KEY-----
        """
        let key = try await vm.importKey(label: "enc", privateKey: pem, passphrase: "pw", publicKey: generated.publicKey)
        XCTAssertEqual(key.passphrase, "pw")
        XCTAssertEqual(key.publicKey, generated.publicKey)
        // Unencrypted key with matching explicit public key (different comment) is accepted.
        let other = SSHKeyGenerator.ed25519(comment: "orig")
        let sameKeyOtherComment = other.publicKey.replacingOccurrences(of: " orig", with: " renamed")
        let ok = try await vm.importKey(label: "ok", privateKey: other.privateKey, passphrase: "", publicKey: sameKeyOtherComment)
        XCTAssertNil(ok.passphrase)
        XCTAssertEqual(ok.publicKey, sameKeyOtherComment)
        // Mismatch throws.
        do {
            _ = try await vm.importKey(label: "bad", privateKey: other.privateKey, passphrase: nil, publicKey: generated.publicKey)
            XCTFail("expected mismatch")
        } catch {
            XCTAssertEqual(error as? KeyImportError, .publicKeyMismatch)
        }
        XCTAssertEqual(vm.keys.count, 2)
    }

    func testImportErrorsSurfaceUnchanged() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        do {
            _ = try await vm.importKey(label: "x", privateKey: "not a key", passphrase: nil, publicKey: nil)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SSHKeyImportError, .unrecognizedFormat)
        }
        let generated = SSHKeyGenerator.ed25519(comment: "")
        do {
            _ = try await vm.importKey(label: "x", privateKey: generated.privateKey, passphrase: nil, publicKey: "garbage")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SSHKeyImportError, .unrecognizedFormat)
        }
        XCTAssertTrue(vm.keys.isEmpty)
    }

    func testDeleteKeyClearsReferencesAndUpdatesUsage() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        let key = try await vm.generateKey(label: "k", type: .ed25519)
        XCTAssertEqual(vm.usageSummary(sshKeyID: key.id), "Not used")
        let identity = try await vault.save(Identity(label: "i", username: "u", sshKeyID: key.id))
        let viaIdentity = try await vault.save(SavedHost(label: "h1", address: "a", identityID: identity.id))
        let direct = try await vault.save(SavedHost(label: "h2", address: "b", sshKeyID: key.id))
        _ = try await vault.save(SavedHost(label: "both", address: "c", identityID: identity.id, sshKeyID: key.id))
        XCTAssertEqual(vm.usageSummary(sshKeyID: key.id), "Used by 3 hosts")
        try await vm.deleteKey(id: key.id)
        XCTAssertTrue(vm.keys.isEmpty)
        XCTAssertNil(vault.get(SavedHost.self, id: direct.id)?.sshKeyID)
        XCTAssertNil(vault.get(Identity.self, id: identity.id)?.sshKeyID)
        XCTAssertEqual(vault.get(SavedHost.self, id: viaIdentity.id)?.identityID, identity.id)
        XCTAssertEqual(vm.usageSummary(sshKeyID: key.id), "Not used")
        XCTAssertNil(vm.publicKeyForCopy(sshKeyID: key.id))
    }

    func testSearchFiltersIdentitiesAndKeys() async throws {
        let vault = try await makeVault()
        _ = try await vault.save(Identity(label: "Work", username: "deploy"))
        _ = try await vault.save(Identity(label: "Home", username: "cory"))
        _ = try await vault.save(SSHKey(label: "Laptop", keyType: .ed25519, publicKey: "p", privateKey: "s"))
        _ = try await vault.save(SSHKey(label: "Server", keyType: .ed25519, publicKey: "p", privateKey: "s"))
        let vm = KeychainViewModel(vault: vault)
        vm.searchText = "DEPLOY"
        XCTAssertEqual(vm.identities.map(\.label), ["Work"])
        XCTAssertTrue(vm.keys.isEmpty)
        vm.searchText = "lap"
        XCTAssertEqual(vm.keys.map(\.label), ["Laptop"])
        vm.searchText = ""
        XCTAssertEqual(vm.identities.count, 2)
        XCTAssertEqual(vm.keys.count, 2)
    }

    // MARK: updateNow

    func testUpdateNowMergesEditableFieldsOntoStoredIdentity() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "p", privateKey: "s"))
        let stored = try await vault.save(Identity(label: "old", username: "u"))
        var edited = stored
        edited.label = "new"
        edited.username = "root"
        edited.password = "pw"
        edited.sshKeyID = key.id
        vm.updateNow(edited)
        let saved = try XCTUnwrap(vault.get(Identity.self, id: stored.id))
        XCTAssertEqual(saved.label, "new")
        XCTAssertEqual(saved.username, "root")
        XCTAssertEqual(saved.password, "pw")
        XCTAssertEqual(saved.sshKeyID, key.id)
        XCTAssertGreaterThan(saved.updatedAt, stored.updatedAt)
        await vault.flush()
        XCTAssertNil(vault.lastSaveError)
    }

    func testUpdateNowClearsMissingKeyAndEmptyPassword() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        let stored = try await vault.save(Identity(label: "i", username: "u", password: "pw"))
        var edited = stored
        edited.password = ""
        edited.sshKeyID = UUID()
        vm.updateNow(edited)
        let saved = try XCTUnwrap(vault.get(Identity.self, id: stored.id))
        XCTAssertNil(saved.password)
        XCTAssertNil(saved.sshKeyID)
    }

    func testUpdateNowIsNoOpAfterDelete() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        let stored = try await vault.save(Identity(label: "i", username: "u"))
        try await vm.deleteIdentity(id: stored.id)
        let revision = vault.revision
        var edited = stored
        edited.label = "resurrected?"
        vm.updateNow(edited)
        XCTAssertNil(vault.get(Identity.self, id: stored.id))
        XCTAssertTrue(vm.identities.isEmpty)
        XCTAssertEqual(vault.revision, revision)
    }

    func testUpdateNowIgnoresUnknownIdentity() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        vm.updateNow(Identity(label: "ghost", username: "g"))
        XCTAssertTrue(vm.identities.isEmpty)
    }

    // MARK: usageCount

    func testUsageCountsMatchSummaries() async throws {
        let vault = try await makeVault()
        let vm = KeychainViewModel(vault: vault)
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "p", privateKey: "s"))
        let identity = try await vault.save(Identity(label: "i", username: "u", sshKeyID: key.id))
        XCTAssertEqual(vm.usageCount(identityID: identity.id), 0)
        XCTAssertEqual(vm.usageCount(sshKeyID: key.id), 0)
        _ = try await vault.save(SavedHost(label: "h1", address: "a", identityID: identity.id))
        XCTAssertEqual(vm.usageCount(identityID: identity.id), 1)
        XCTAssertEqual(vm.usageCount(sshKeyID: key.id), 1)
        _ = try await vault.save(SavedHost(label: "h2", address: "b", sshKeyID: key.id))
        XCTAssertEqual(vm.usageCount(identityID: identity.id), 1)
        XCTAssertEqual(vm.usageCount(sshKeyID: key.id), 2)
        XCTAssertEqual(vm.usageSummary(sshKeyID: key.id), "Used by 2 hosts")
    }
}
