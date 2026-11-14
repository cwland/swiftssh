import XCTest
import CoreModels
import SyncCore
@testable import AppCore

@MainActor
final class HostDetailsViewModelTests: XCTestCase {
    private func makeVault(_ p: InMemoryVaultPersistence = InMemoryVaultPersistence()) async throws -> LocalVault {
        try await LocalVault.open(persistence: p, newDeviceID: { "dev-1" })
    }

    private func persistedHost(_ p: InMemoryVaultPersistence, id: UUID) async throws -> SavedHost {
        let contents = await p.contents
        let record = try XCTUnwrap(contents?.records.first { $0.id == id })
        return try record.decode(SavedHost.self)
    }

    func testEditingLabelSavesImmediately() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let host = try await vault.save(SavedHost(label: "old", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.label, "old")
        vm.label = "new"
        vm.address = "b.example"
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.label, "new")
        XCTAssertEqual(vm.label, "new")
        XCTAssertEqual(vm.address, "b.example")
        await vault.flush()
        let stored = try await persistedHost(p, id: host.id)
        XCTAssertEqual(stored.label, "new")
        XCTAssertEqual(stored.address, "b.example")
    }

    func testRapidEditsKeepLastValueAndIncreasingTimestamps() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let host = try await vault.save(SavedHost(label: "", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        var previous = host.updatedAt
        var text = ""
        for i in 0..<20 {
            text += "\(i % 10)"
            vm.label = text
            let current = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
            XCTAssertGreaterThan(current.updatedAt, previous)
            previous = current.updatedAt
        }
        await vault.flush()
        let stored = try await persistedHost(p, id: host.id)
        XCTAssertEqual(stored.label, text)
        XCTAssertEqual(stored.updatedAt, previous)
        XCTAssertNil(vault.lastSaveError)
    }

    func testInvalidPortShowsErrorAndDoesNotSave() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", port: 2200))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.portText, "2200")
        XCTAssertNil(vm.portError)
        XCTAssertNil(vm.inheritedPortHint)

        vm.portText = "70000"
        XCTAssertEqual(vm.portError, "Port must be 1–65535")
        XCTAssertEqual(vm.portText, "70000")
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.port, 2200)
        XCTAssertEqual(vm.effectivePort, 2200)

        vm.portText = "abc"
        XCTAssertEqual(vm.portError, "Port must be 1–65535")
        vm.portText = "0"
        XCTAssertEqual(vm.portError, "Port must be 1–65535")
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.port, 2200)

        vm.portText = "2222"
        XCTAssertNil(vm.portError)
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.port, 2222)

        vm.portText = ""
        XCTAssertNil(vm.portError)
        XCTAssertEqual(vm.portText, "")
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.port)
        XCTAssertEqual(vm.inheritedPortHint, "22 (default)")
        XCTAssertEqual(vm.effectivePort, 22)
        await vault.flush()
        let stored = try await persistedHost(p, id: host.id)
        XCTAssertNil(stored.port)
    }

    func testInheritedPortHintNamesGroup() async throws {
        let vault = try await makeVault()
        let parent = try await vault.save(HostGroup(name: "Proxmox", defaultPort: 2222))
        let child = try await vault.save(HostGroup(name: "Nodes", parentID: parent.id))
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", groupID: child.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.inheritedPortHint, "2222 (from group Proxmox)")
        XCTAssertEqual(vm.effectivePort, 2222)
        vm.portText = "2200"
        XCTAssertNil(vm.inheritedPortHint)
        XCTAssertEqual(vm.effectivePort, 2200)
    }

    func testTagsAreTrimmedDeduplicated() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.tags = [" prod ", "", "db", "prod", "  ", "db "]
        XCTAssertEqual(vm.tags, ["prod", "db"])
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.tags, ["prod", "db"])
    }

    func testManualBadgeSetsManualFlag() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", osBadge: .ubuntu))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.osBadge, .ubuntu)
        vm.osBadge = .debian
        let stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.osBadge, .debian)
        XCTAssertTrue(stored.osBadgeIsManual)
        XCTAssertEqual(vm.osBadge, .debian)
    }

    func testAutomaticOSClearsTheManualChoice() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", osBadge: .ubuntu))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertTrue(vm.isOSAutomatic)
        vm.osBadge = .proxmox
        XCTAssertFalse(vm.isOSAutomatic)
        vm.useAutomaticOS()
        let stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertNil(stored.osBadge, "cleared so the next connection detects it")
        XCTAssertFalse(stored.osBadgeIsManual)
        XCTAssertTrue(vm.isOSAutomatic)
        XCTAssertNil(vm.osBadge)
    }

    func testManualBadgeAcceptsAnyCatalogID() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.osBadge = .xcpng
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.osBadge?.rawValue, "xcpng")
    }

    func testSwitchingCredentialModeClearsTheOtherMode() async throws {
        let vault = try await makeVault()
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv"))
        let identity = try await vault.save(Identity(label: "cory", username: "cory"))
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", username: "root",
                                                  password: "pw", sshKeyID: key.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.credentialMode, .direct)
        XCTAssertEqual(vm.username, "root")
        XCTAssertEqual(vm.password, "pw")
        XCTAssertEqual(vm.sshKeyID, key.id)
        XCTAssertEqual(vm.availableKeys, [key])
        XCTAssertEqual(vm.availableIdentities, [identity])

        vm.credentialMode = .identity
        XCTAssertEqual(vm.credentialMode, .identity)
        var stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertNil(stored.username)
        XCTAssertNil(stored.password)
        XCTAssertNil(stored.sshKeyID)
        XCTAssertEqual(vm.username, "")

        vm.identityID = identity.id
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.identityID, identity.id)

        vm.credentialMode = .direct
        XCTAssertEqual(vm.credentialMode, .direct)
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertNil(stored.identityID)

        vm.username = "admin"
        vm.password = "secret"
        vm.sshKeyID = key.id
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.username, "admin")
        XCTAssertEqual(stored.password, "secret")
        XCTAssertEqual(stored.sshKeyID, key.id)
        vm.username = ""
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.username)
    }

    func testReuseHintAndCreateIdentityLinksAllHosts() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv"))
        let hosts = [
            try await vault.save(SavedHost(label: "a", address: "a.example", username: "cory", password: "pw",
                                           sshKeyID: key.id)),
            try await vault.save(SavedHost(label: "b", address: "b.example", username: "cory", password: "pw")),
            try await vault.save(SavedHost(label: "c", address: "c.example", username: "cory", password: "pw")),
        ]
        let other = try await vault.save(SavedHost(label: "d", address: "d.example", username: "x", password: "y"))
        let vm = HostDetailsViewModel(vault: vault, hostID: hosts[1].id)
        XCTAssertEqual(vm.reuseHint, "3 hosts reuse credentials. Merge them for easy updates.")
        XCTAssertNil(HostDetailsViewModel(vault: vault, hostID: other.id).reuseHint)

        let identity = try await vm.createIdentityFromReusedCredentials()
        XCTAssertEqual(identity.label, "cory credentials")
        XCTAssertEqual(identity.username, "cory")
        XCTAssertEqual(identity.password, "pw")
        XCTAssertEqual(vault.get(Identity.self, id: identity.id), identity)
        await vault.flush()
        for host in hosts {
            let stored = try await persistedHost(p, id: host.id)
            XCTAssertEqual(stored.identityID, identity.id)
            XCTAssertNil(stored.username)
            XCTAssertNil(stored.password)
            XCTAssertNil(stored.sshKeyID, "the identity is now the host's only credential source")
        }
        let storedOther = try await persistedHost(p, id: other.id)
        XCTAssertEqual(storedOther.username, "x")
        XCTAssertNil(vm.reuseHint)
        XCTAssertEqual(vm.credentialMode, .identity)
        XCTAssertEqual(vm.identityID, identity.id)
    }

    func testCreateIdentityIsAtomicInMemoryWhenPersistFails() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let hosts = [
            try await vault.save(SavedHost(label: "a", address: "a.example", username: "cory", password: "pw")),
            try await vault.save(SavedHost(label: "b", address: "b.example", username: "cory", password: "pw")),
            try await vault.save(SavedHost(label: "c", address: "c.example", username: "cory", password: "pw")),
        ]
        let vm = HostDetailsViewModel(vault: vault, hostID: hosts[0].id)
        await p.setFailing(true)
        do {
            _ = try await vm.createIdentityFromReusedCredentials()
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is InMemoryPersistenceError)
        }
        XCTAssertNotNil(vault.lastSaveError)
        let identities = vault.all(Identity.self)
        XCTAssertEqual(identities.count, 1)
        let identity = try XCTUnwrap(identities.first)
        for host in hosts {
            let stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
            XCTAssertEqual(stored.identityID, identity.id)
            XCTAssertNil(stored.username)
            XCTAssertNil(stored.password)
        }
        await p.setFailing(false)
        await vault.flush()
        XCTAssertNil(vault.lastSaveError)
        for host in hosts {
            let stored = try await persistedHost(p, id: host.id)
            XCTAssertEqual(stored.identityID, identity.id)
            XCTAssertNil(stored.username)
        }
        let contents = await p.contents
        XCTAssertNotNil(contents?.records.first { $0.id == identity.id })
    }

    func testCredentialModeFollowsStoredHost() async throws {
        let vault = try await makeVault()
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv"))
        let identity = try await vault.save(Identity(label: "cory", username: "cory"))
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)

        // Picked identity but none chosen yet: stays in identity mode.
        vm.credentialMode = .identity
        XCTAssertEqual(vm.credentialMode, .identity)

        // Choosing an identity elsewhere and then unlinking it elsewhere: mode follows storage.
        var stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        stored.identityID = identity.id
        try await vault.save(stored)
        XCTAssertEqual(vm.credentialMode, .identity)
        try await vault.deleteIdentity(id: identity.id)
        XCTAssertEqual(vm.credentialMode, .identity, "user picked identity mode and has no identity yet")
        vm.credentialMode = .direct
        XCTAssertEqual(vm.credentialMode, .direct)

        // Linked externally while the VM thinks direct: derived from storage.
        let other = try await vault.save(Identity(label: "o", username: "o"))
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        stored.identityID = other.id
        try await vault.save(stored)
        XCTAssertEqual(vm.credentialMode, .identity)

        // Setting a direct field while an identity is linked clears the identity.
        vm.sshKeyID = key.id
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertNil(stored.identityID)
        XCTAssertEqual(stored.sshKeyID, key.id)
        XCTAssertEqual(vm.credentialMode, .direct)
        vm.username = "root"
        vm.password = "pw"

        // Setting an identity clears the direct fields.
        vm.identityID = other.id
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.identityID, other.id)
        XCTAssertNil(stored.username)
        XCTAssertNil(stored.password)
        XCTAssertNil(stored.sshKeyID)
        XCTAssertEqual(vm.credentialMode, .identity)

        vm.password = "secret"
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertNil(stored.identityID)
        XCTAssertEqual(stored.password, "secret")
        XCTAssertEqual(vm.credentialMode, .direct)
    }

    func testNonCanonicalPortTextSavesPortAndKeepsRawText() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        for text in ["022", " 22", "22 "] {
            vm.portText = text
            XCTAssertEqual(vm.portText, text)
            XCTAssertNil(vm.portError)
            XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.port, 22)
        }
        vm.portText = "2222"
        XCTAssertEqual(vm.portText, "2222")
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.port, 2222)

        vm.portText = "+22"
        XCTAssertEqual(vm.portText, "+22")
        XCTAssertEqual(vm.portError, "Port must be 1–65535")
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.port, 2222)
        vm.portText = "-22"
        XCTAssertEqual(vm.portError, "Port must be 1–65535")
        vm.portText = "99999999999999999999999"
        XCTAssertEqual(vm.portError, "Port must be 1–65535")

        // Raw text is dropped once the stored port changes elsewhere.
        vm.portText = "0080"
        XCTAssertEqual(vm.portText, "0080")
        var stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        stored.port = 443
        try await vault.save(stored)
        XCTAssertEqual(vm.portText, "443")
    }

    func testCreateIdentityWithoutReuseGroupThrows() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", username: "cory", password: "pw"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        do {
            _ = try await vm.createIdentityFromReusedCredentials()
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? HostDetailsError, .noReusedCredentials)
        }
        XCTAssertTrue(vault.all(Identity.self).isEmpty)
    }

    func testSwitchingHostsMidEditLosesNothing() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let a = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let b = try await vault.save(SavedHost(label: "b", address: "b.example"))
        let vmA = HostDetailsViewModel(vault: vault, hostID: a.id)
        vmA.label = "a-edited"
        vmA.tags = ["x"]
        let vmB = HostDetailsViewModel(vault: vault, hostID: b.id)
        vmB.label = "b-edited"
        vmA.address = "a2.example"
        await vault.flush()
        let storedA = try await persistedHost(p, id: a.id)
        let storedB = try await persistedHost(p, id: b.id)
        XCTAssertEqual(storedA.label, "a-edited")
        XCTAssertEqual(storedA.tags, ["x"])
        XCTAssertEqual(storedA.address, "a2.example")
        XCTAssertEqual(storedB.label, "b-edited")
    }

    func testEditsMadeElsewhereAreNotOverwritten() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        var external = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        external.address = "elsewhere.example"
        try await vault.save(external)
        vm.label = "edited"
        let stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.label, "edited")
        XCTAssertEqual(stored.address, "elsewhere.example")
        XCTAssertEqual(vm.address, "elsewhere.example")
    }

    func testAvailableGroupsSortedByNameWithoutDeleted() async throws {
        let vault = try await makeVault()
        let zeta = try await vault.save(HostGroup(name: "zeta"))
        let alpha = try await vault.save(HostGroup(name: "Alpha"))
        let gone = try await vault.save(HostGroup(name: "gone"))
        try await vault.delete(HostGroup.self, id: gone.id)
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.availableGroups, [alpha, zeta])
        vm.groupID = alpha.id
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.groupID, alpha.id)
        XCTAssertEqual(vm.groupID, alpha.id)
    }

    func testDeleteTombstonesHost() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertFalse(vm.isDeleted)
        try await vm.delete()
        XCTAssertTrue(vm.isDeleted)
        XCTAssertNil(vault.get(SavedHost.self, id: host.id))
        let contents = await p.contents
        XCTAssertTrue(try XCTUnwrap(contents?.records.first { $0.id == host.id }).deleted)
        let revision = vault.revision
        vm.label = "ghost"
        vm.portText = "2222"
        XCTAssertEqual(vault.revision, revision)
        XCTAssertNil(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(vm.label, "")
    }

    // MARK: 1Password agent key

    func testSettingAgentKeySavesAndUnlinksTheIdentity() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "u"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", identityID: identity.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertNil(vm.agentKey)
        XCTAssertEqual(vm.credentialMode, .identity)

        vm.agentKey = AgentKeyChoice(publicKey: nil)
        let saved = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(saved.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertNil(saved.identityID)
        XCTAssertEqual(vm.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertEqual(vm.credentialMode, .direct)

        vm.agentKey = AgentKeyChoice(publicKey: "ssh-ed25519 AAAA pin")
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.agentKey?.publicKey, "ssh-ed25519 AAAA pin")
    }

    func testAgentKeyKeepsTheStoredPasswordAndKey() async throws {
        let vault = try await makeVault()
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "p", privateKey: "s"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  password: "pw", sshKeyID: key.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.agentKey = AgentKeyChoice(publicKey: nil)
        vm.agentKey = nil // back to password or key: both are still there
        let saved = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertNil(saved.agentKey)
        XCTAssertEqual(saved.password, "pw")
        XCTAssertEqual(saved.sshKeyID, key.id)
        XCTAssertEqual(saved.username, "root")
    }

    func testClearingAgentKeyKeepsALinkedIdentityAlone() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "u"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", identityID: identity.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        let revision = vault.revision
        vm.agentKey = nil
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.identityID, identity.id)
        XCTAssertEqual(vault.revision, revision, "nothing changed, nothing saved")
    }

    func testAgentKeyAloneCountsAsDirectCredentials() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "h", address: "h.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.credentialMode = .identity
        XCTAssertEqual(vm.credentialMode, .identity)
        vm.agentKey = AgentKeyChoice(publicKey: nil)
        XCTAssertEqual(vm.credentialMode, .direct)

        let other = try await vault.save(SavedHost(label: "o", address: "o.example",
                                                   agentKey: AgentKeyChoice(publicKey: nil)))
        let otherVM = HostDetailsViewModel(vault: vault, hostID: other.id)
        otherVM.credentialMode = .direct
        XCTAssertEqual(otherVM.credentialMode, .direct)
    }

    func testSwitchingToIdentityModeOrLinkingAnIdentityClearsAgentKey() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "u"))
        let a = try await vault.save(SavedHost(label: "a", address: "a.example", username: "root",
                                               agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 AAAA pin")))
        let b = try await vault.save(SavedHost(label: "b", address: "b.example",
                                               agentKey: AgentKeyChoice(publicKey: nil)))
        HostDetailsViewModel(vault: vault, hostID: a.id).credentialMode = .identity
        XCTAssertNil(vault.get(SavedHost.self, id: a.id)?.agentKey)
        XCTAssertNil(vault.get(SavedHost.self, id: a.id)?.username)
        HostDetailsViewModel(vault: vault, hostID: b.id).identityID = identity.id
        let linked = try XCTUnwrap(vault.get(SavedHost.self, id: b.id))
        XCTAssertNil(linked.agentKey)
        XCTAssertEqual(linked.identityID, identity.id)
    }

    func testAgentKeySetIsIgnoredOnceTheHostIsDeleted() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "h", address: "h.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        try await vm.delete()
        vm.agentKey = AgentKeyChoice(publicKey: nil)
        XCTAssertNil(vault.get(SavedHost.self, id: host.id))
        XCTAssertNil(vm.agentKey)
    }
}
