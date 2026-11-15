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

    func testSwitchingCredentialModeKeepsBothSidesAndUsesOnlyTheChosenOne() async throws {
        let vault = try await makeVault()
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv"))
        let identity = try await vault.save(Identity(label: "cory", username: "cory", password: "idpw"))
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", username: "root",
                                                  password: "pw", sshKeyID: key.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.credentialMode, .direct)
        XCTAssertEqual(vm.availableKeys, [key])
        XCTAssertEqual(vm.availableIdentities, [identity])

        vm.credentialMode = .identity
        vm.identityID = identity.id
        var stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.identityID, identity.id)
        XCTAssertEqual(stored.username, "root", "the direct credentials are kept")
        XCTAssertEqual(stored.password, "pw")
        XCTAssertEqual(stored.sshKeyID, key.id)
        XCTAssertEqual(vm.credentialMode, .identity)
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: host.id, vault: vault).username, "cory",
                       "identity mode uses only the identity")

        vm.credentialMode = .direct
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.identityID, identity.id, "the identity stays linked for switching back")
        XCTAssertEqual(stored.prefersIdentity, false)
        XCTAssertEqual(vm.credentialMode, .direct)
        XCTAssertEqual(vm.username, "root")
        XCTAssertEqual(vm.password, "pw")
        XCTAssertEqual(vm.sshKeyID, key.id)
        XCTAssertEqual(vm.identityID, identity.id)
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "root", "direct mode ignores the linked identity")
        XCTAssertEqual(HostsViewModel(vault: vault).subtitle(for: stored), "ssh, root")

        vm.credentialMode = .identity
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: host.id, vault: vault).username, "cory",
                       "switching back needs no re-entry")

        vm.credentialMode = .direct
        vm.username = "admin"
        vm.password = "secret"
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.username, "admin")
        XCTAssertEqual(stored.password, "secret")
        XCTAssertEqual(stored.identityID, identity.id)
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
            XCTAssertEqual(stored.username, "cory", "linking an identity never clears the username")
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
            XCTAssertEqual(stored.username, "cory")
            XCTAssertNil(stored.password)
        }
        await p.setFailing(false)
        await vault.flush()
        XCTAssertNil(vault.lastSaveError)
        for host in hosts {
            let stored = try await persistedHost(p, id: host.id)
            XCTAssertEqual(stored.identityID, identity.id)
            XCTAssertEqual(stored.username, "cory")
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

        // Linked on another Mac (identity mode recorded there): derived from storage.
        let other = try await vault.save(Identity(label: "o", username: "o"))
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        stored.identityID = other.id
        stored.prefersIdentity = true
        try await vault.save(stored)
        XCTAssertEqual(vm.credentialMode, .identity)

        // Setting a direct field records direct mode; the identity stays linked.
        vm.sshKeyID = key.id
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.identityID, other.id)
        XCTAssertEqual(stored.sshKeyID, key.id)
        XCTAssertEqual(vm.credentialMode, .direct)
        vm.username = "root"
        vm.password = "pw"

        // Choosing an identity again keeps the direct password and key.
        vm.identityID = other.id
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.identityID, other.id)
        XCTAssertEqual(stored.username, "root")
        XCTAssertEqual(stored.password, "pw")
        XCTAssertEqual(stored.sshKeyID, key.id)
        XCTAssertEqual(vm.credentialMode, .identity)

        vm.password = "secret"
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.identityID, other.id)
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

    func testSettingAgentKeySavesSwitchesToDirectAndKeepsTheIdentity() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "u"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  identityID: identity.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertNil(vm.agentKey)
        XCTAssertEqual(vm.credentialMode, .identity)

        vm.agentKey = AgentKeyChoice(publicKey: nil)
        let saved = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(saved.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertEqual(saved.identityID, identity.id, "kept for switching back")
        XCTAssertEqual(vm.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertEqual(vm.credentialMode, .direct)
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: host.id, vault: vault).agentKey,
                       AgentKeyChoice(publicKey: nil), "direct mode signs in with the agent")

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

    func testSwitchingToIdentityModeOrLinkingAnIdentityKeepsTheAgentKeyUnused() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "u"))
        let a = try await vault.save(SavedHost(label: "a", address: "a.example", username: "root",
                                               agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 AAAA pin")))
        let b = try await vault.save(SavedHost(label: "b", address: "b.example",
                                               agentKey: AgentKeyChoice(publicKey: nil)))
        HostDetailsViewModel(vault: vault, hostID: a.id).credentialMode = .identity
        XCTAssertEqual(vault.get(SavedHost.self, id: a.id)?.agentKey?.publicKey, "ssh-ed25519 AAAA pin")
        XCTAssertEqual(vault.get(SavedHost.self, id: a.id)?.username, "root")
        XCTAssertNil(try? ConnectionPlanner.plan(hostID: a.id, vault: vault),
                     "identity mode without an identity: the kept agent key isn't used")
        HostDetailsViewModel(vault: vault, hostID: b.id).identityID = identity.id
        let linked = try XCTUnwrap(vault.get(SavedHost.self, id: b.id))
        XCTAssertEqual(linked.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertEqual(linked.identityID, identity.id)
        let plan = try ConnectionPlanner.plan(hostID: b.id, vault: vault)
        XCTAssertEqual(plan.username, "u")
        XCTAssertNil(plan.agentKey, "the identity applies, not the host's agent key")
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

    // MARK: Username is kept across login methods

    func testKeptUsernameNeverOverridesALinkedIdentity() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "idUser", password: "idpw"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root", password: "pw"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.identityID = identity.id
        let stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.username, "root")
        XCTAssertEqual(vm.credentialMode, .identity)

        let plan = try ConnectionPlanner.plan(hostID: stored.id, vault: vault)
        XCTAssertEqual(plan.username, "idUser", "the identity applies first")
        XCTAssertEqual(HostsViewModel(vault: vault).subtitle(for: stored), "ssh, idUser",
                       "the card shows the user actually used")
    }

    func testIdentityModeWithoutIdentityKeepsUsernameAndStaysInIdentityMode() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  agentKey: AgentKeyChoice(publicKey: nil)))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.credentialMode = .identity
        XCTAssertEqual(vm.credentialMode, .identity)
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.username, "root")
        XCTAssertEqual(HostDetailsViewModel(vault: vault, hostID: host.id).credentialMode, .identity,
                       "the choice is stored, so a fresh editor sees identity mode too")
        vm.credentialMode = .direct
        XCTAssertEqual(vm.username, "root")
    }

    // MARK: Idempotent setters

    func testWritingTheStoredCredentialValuesChangesNothing() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv"))
        let identity = try await vault.save(Identity(label: "i", username: "alice", password: "pw"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  identityID: identity.id, password: "secret", sshKeyID: key.id,
                                                  prefersIdentity: true))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        let before = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        vm.username = "root"
        vm.password = "secret"
        vm.sshKeyID = key.id
        let after = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(after, before, "no identity unlink, no prefersIdentity flip, no save")
        XCTAssertEqual(after.updatedAt, before.updatedAt)
        XCTAssertEqual(after.identityID, identity.id)
        XCTAssertEqual(after.prefersIdentity, true)
    }

    func testWritingEmptyToAnUnsetFieldChangesNothing() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "alice"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", identityID: identity.id,
                                                  prefersIdentity: true))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        let before = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        vm.username = ""
        vm.password = ""
        vm.sshKeyID = nil
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id), before)
        XCTAssertEqual(vm.credentialMode, .identity)
    }

    func testWritingADifferentUsernameSwitchesToDirectAndKeepsTheIdentity() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "alice"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  identityID: identity.id, prefersIdentity: true))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.username = "other"
        let after = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(after.identityID, identity.id)
        XCTAssertEqual(after.prefersIdentity, false)
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: host.id, vault: vault).username, "other")
        XCTAssertEqual(after.username, "other")
    }

    // MARK: Replacing credentials

    private func keyItem(_ vault: LocalVault) async throws -> SSHKey {
        try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv"))
    }

    func testAgentReplacesPlainPasswordAndKeyLink() async throws {
        let vault = try await makeVault()
        let key = try await keyItem(vault)
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  password: "pw", sshKeyID: key.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        let change = CredentialChange.agent(AgentKeyChoice(publicKey: "ssh-ed25519 AAAA pin"))
        XCTAssertEqual(vm.secretsReplaced(by: change), ReplacedSecrets(password: true, keyLink: true))
        vm.apply(change, removingReplaced: true)
        let saved = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(saved.agentKey, AgentKeyChoice(publicKey: "ssh-ed25519 AAAA pin"))
        XCTAssertNil(saved.password)
        XCTAssertNil(saved.sshKeyID)
        XCTAssertEqual(saved.username, "root")
        XCTAssertNotNil(vault.get(SSHKey.self, id: key.id), "the key item itself stays in Keychain")
        XCTAssertTrue(vm.secretsReplaced(by: change).isEmpty)
    }

    func testAgentKeepsAReferencePasswordAndDoesNotCountIt() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  password: " op://Private/web/password"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        let change = CredentialChange.agent(AgentKeyChoice(publicKey: nil))
        XCTAssertEqual(vm.secretsReplaced(by: change), ReplacedSecrets(password: false, keyLink: false))
        XCTAssertTrue(vm.secretsReplaced(by: change).isEmpty)
        vm.apply(change, removingReplaced: true)
        let saved = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(saved.password, " op://Private/web/password", "a reference isn't a secret; it is kept")
        XCTAssertEqual(saved.agentKey, AgentKeyChoice(publicKey: nil))
    }

    func testPasswordReferenceOverwritesPasswordAndReplacesKeyLink() async throws {
        let vault = try await makeVault()
        let key = try await keyItem(vault)
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  password: "pw", sshKeyID: key.id,
                                                  agentKey: AgentKeyChoice(publicKey: nil)))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        let change = CredentialChange.passwordReference("op://Private/web/password")
        XCTAssertEqual(vm.secretsReplaced(by: change), ReplacedSecrets(password: false, keyLink: true),
                       "the password is overwritten either way; only the key link is a choice")
        vm.apply(change, removingReplaced: true)
        let saved = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(saved.password, "op://Private/web/password")
        XCTAssertNil(saved.sshKeyID)
        XCTAssertNil(saved.agentKey, "the password is what logs in now")
        XCTAssertEqual(saved.username, "root")
        XCTAssertNotNil(vault.get(SSHKey.self, id: key.id))
    }

    func testPasswordReferenceWithoutKeyLinkCountsNothing() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", password: "op://a/b/c"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertTrue(vm.secretsReplaced(by: .passwordReference("op://a/b/d")).isEmpty)
        let plain = try await vault.save(SavedHost(label: "p", address: "p.example", password: "pw"))
        XCTAssertTrue(HostDetailsViewModel(vault: vault, hostID: plain.id)
            .secretsReplaced(by: .passwordReference("op://a/b/d")).isEmpty, "a plain password alone asks nothing")
        vm.apply(.passwordReference("op://a/b/d"), removingReplaced: false)
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.password, "op://a/b/d")
    }

    func testKeyReplacesPlainPasswordAndClearsAgent() async throws {
        let vault = try await makeVault()
        let old = try await keyItem(vault)
        let new = try await keyItem(vault)
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  password: "pw", sshKeyID: old.id,
                                                  agentKey: AgentKeyChoice(publicKey: nil)))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.secretsReplaced(by: .key(new.id)), ReplacedSecrets(password: true, keyLink: false))
        vm.apply(.key(new.id), removingReplaced: true)
        let saved = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(saved.sshKeyID, new.id)
        XCTAssertNil(saved.agentKey)
        XCTAssertNil(saved.password)
        XCTAssertEqual(saved.username, "root")
        XCTAssertNotNil(vault.get(SSHKey.self, id: old.id), "the old key item is kept")
    }

    func testKeyKeepsAReferencePassword() async throws {
        let vault = try await makeVault()
        let key = try await keyItem(vault)
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", password: "op://a/b/c"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertTrue(vm.secretsReplaced(by: .key(key.id)).isEmpty)
        vm.apply(.key(key.id), removingReplaced: true)
        let saved = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(saved.password, "op://a/b/c")
        XCTAssertEqual(saved.sshKeyID, key.id)
    }

    func testNotRemovingReplacedKeepsTheFields() async throws {
        let vault = try await makeVault()
        let key = try await keyItem(vault)
        let other = try await keyItem(vault)
        func fresh() async throws -> HostDetailsViewModel {
            let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                      password: "pw", sshKeyID: key.id))
            return HostDetailsViewModel(vault: vault, hostID: host.id)
        }
        var vm = try await fresh()
        vm.apply(.agent(AgentKeyChoice(publicKey: nil)), removingReplaced: false)
        var saved = try XCTUnwrap(vault.get(SavedHost.self, id: vm.hostID))
        XCTAssertEqual(saved.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertEqual(saved.password, "pw")
        XCTAssertEqual(saved.sshKeyID, key.id)

        vm = try await fresh()
        vm.apply(.passwordReference("op://a/b/c"), removingReplaced: false)
        saved = try XCTUnwrap(vault.get(SavedHost.self, id: vm.hostID))
        XCTAssertEqual(saved.password, "op://a/b/c", "the reference takes the password's place")
        XCTAssertEqual(saved.sshKeyID, key.id)

        vm = try await fresh()
        vm.apply(.key(other.id), removingReplaced: false)
        saved = try XCTUnwrap(vault.get(SavedHost.self, id: vm.hostID))
        XCTAssertEqual(saved.sshKeyID, other.id)
        XCTAssertEqual(saved.password, "pw")
        XCTAssertEqual(saved.username, "root")
    }

    func testApplySwitchesToDirectKeepsIdentityAndUsernameAndPersists() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let identity = try await vault.save(Identity(label: "i", username: "u"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  identityID: identity.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertTrue(vm.secretsReplaced(by: .agent(AgentKeyChoice(publicKey: nil))).isEmpty,
                      "only the host's direct credentials count")
        let revision = vault.revision
        vm.apply(.agent(AgentKeyChoice(publicKey: nil)), removingReplaced: true)
        XCTAssertGreaterThan(vault.revision, revision)
        XCTAssertEqual(vm.credentialMode, .direct)
        await vault.flush()
        let stored = try await persistedHost(p, id: host.id)
        XCTAssertEqual(stored.identityID, identity.id)
        XCTAssertEqual(stored.prefersIdentity, false)
        XCTAssertEqual(stored.username, "root")
        XCTAssertEqual(stored.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertNotNil(vault.get(Identity.self, id: identity.id))
    }

    func testReplacingOnADeletedHostDoesNothing() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", password: "pw"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        try await vm.delete()
        XCTAssertTrue(vm.secretsReplaced(by: .agent(AgentKeyChoice(publicKey: nil))).isEmpty)
        vm.apply(.agent(AgentKeyChoice(publicKey: nil)), removingReplaced: true)
        XCTAssertNil(vault.get(SavedHost.self, id: host.id))
    }

    func testReplacedSecretsIsEmpty() async {
        XCTAssertTrue(ReplacedSecrets(password: false, keyLink: false).isEmpty)
        XCTAssertFalse(ReplacedSecrets(password: true, keyLink: false).isEmpty)
        XCTAssertFalse(ReplacedSecrets(password: false, keyLink: true).isEmpty)
    }

    // MARK: Persisted login-method choice

    func testIdentityModeIsPersistedAndUsesTheGroupDefaultWhileKeepingTheUsername() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let groupIdentity = try await vault.save(Identity(label: "g", username: "groupUser", password: "gpw"))
        let group = try await vault.save(HostGroup(name: "G", defaultIdentityID: groupIdentity.id))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", groupID: group.id,
                                                  username: "root", password: "pw"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.credentialMode = .identity
        var stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.prefersIdentity, true)
        XCTAssertEqual(stored.username, "root")
        XCTAssertEqual(stored.password, "pw", "kept, unused in identity mode")
        XCTAssertEqual(HostDetailsViewModel(vault: vault, hostID: host.id).credentialMode, .identity,
                       "a fresh editor (another Mac) sees identity mode")
        var plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "groupUser")
        guard case .password("gpw") = plan.credential else { return XCTFail("\(plan.credential)") }
        XCTAssertEqual(HostsViewModel(vault: vault).subtitle(for: stored), "ssh, groupUser")

        vm.credentialMode = .direct
        stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.prefersIdentity, false)
        XCTAssertEqual(vm.username, "root")
        XCTAssertEqual(HostDetailsViewModel(vault: vault, hostID: host.id).credentialMode, .direct)
        plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "root", "back in direct mode the kept username is used")
        XCTAssertEqual(HostsViewModel(vault: vault).subtitle(for: stored), "ssh, root")

        await vault.flush()
        let persisted = try await persistedHost(p, id: host.id)
        XCTAssertEqual(persisted.prefersIdentity, false, "synced with the record")
    }

    func testLegacyHostKeepsInferredMode() async throws {
        let vault = try await makeVault()
        let bare = try await vault.save(SavedHost(label: "b", address: "b.example"))
        let withUser = try await vault.save(SavedHost(label: "u", address: "u.example", username: "root"))
        XCTAssertNil(bare.prefersIdentity)
        XCTAssertEqual(HostDetailsViewModel(vault: vault, hostID: bare.id).credentialMode, .direct)
        XCTAssertEqual(HostDetailsViewModel(vault: vault, hostID: withUser.id).credentialMode, .direct)
    }

    func testDirectEditsAndLinkingUpdateThePersistedChoice() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "u"))
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root",
                                                  prefersIdentity: true))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.credentialMode, .identity)
        vm.password = "pw"
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.prefersIdentity, false, "a direct secret means direct")
        XCTAssertEqual(vm.credentialMode, .direct)

        vm.identityID = identity.id
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.prefersIdentity, true)
        vm.apply(.agent(AgentKeyChoice(publicKey: nil)), removingReplaced: true)
        let stored = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        XCTAssertEqual(stored.prefersIdentity, false)
        XCTAssertEqual(stored.identityID, identity.id)
        XCTAssertEqual(stored.username, "root")
        XCTAssertEqual(vm.credentialMode, .direct)
    }

    func testRecordFromAnotherDeviceDrivesTheMode() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "h", address: "h.example", username: "root"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.credentialMode, .direct)
        var synced = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        synced.prefersIdentity = true
        try await vault.save(synced)
        XCTAssertEqual(vm.credentialMode, .identity)
        synced.prefersIdentity = false
        try await vault.save(synced)
        XCTAssertEqual(vm.credentialMode, .direct)
    }

    // MARK: Theme

    func testThemeIDDefaultsToNil() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertNil(vm.themeID)
        XCTAssertNil(vm.unknownThemeID)
    }

    func testSettingThemeIDSavesImmediately() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await makeVault(p)
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", username: "root"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.themeID = "nord"
        XCTAssertEqual(vm.themeID, "nord")
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.themeID, "nord")
        XCTAssertEqual(vm.username, "root")
        await vault.flush()
        let stored = try await persistedHost(p, id: host.id)
        XCTAssertEqual(stored.themeID, "nord")
    }

    func testSettingSameThemeIDDoesNotSaveAgain() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", themeID: "nord"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        let before = try XCTUnwrap(vault.get(SavedHost.self, id: host.id)).updatedAt
        vm.themeID = "nord"
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.updatedAt, before)
    }

    func testSettingThemeIDNilClearsIt() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", themeID: "nord"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        vm.themeID = nil
        XCTAssertNil(vm.themeID)
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.themeID)
    }

    func testInheritedThemeIDFromGroup() async throws {
        let vault = try await makeVault()
        let parent = try await vault.save(HostGroup(name: "P", defaultThemeID: "dracula"))
        let child = try await vault.save(HostGroup(name: "C", parentID: parent.id))
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", groupID: child.id, themeID: "nord"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        // The host's own theme is not part of what "Default" resolves to.
        XCTAssertEqual(vm.inheritedThemeID, "dracula")
        vm.themeID = nil
        XCTAssertEqual(vm.inheritedThemeID, "dracula")
    }

    func testInheritedThemeIDIgnoresUnknownGroupTheme() async throws {
        let vault = try await makeVault()
        let parent = try await vault.save(HostGroup(name: "P", defaultThemeID: "nord"))
        let child = try await vault.save(HostGroup(name: "C", parentID: parent.id, defaultThemeID: "from-the-future"))
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", groupID: child.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.inheritedThemeID, "nord")
        let loose = try await vault.save(SavedHost(label: "b", address: "b.example"))
        XCTAssertNil(HostDetailsViewModel(vault: vault, hostID: loose.id).inheritedThemeID)
    }

    func testUnknownThemeIDReportedForUnknownStoredID() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", themeID: "from-the-future"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.unknownThemeID, "from-the-future")
        XCTAssertEqual(vm.themeID, "from-the-future")
        vm.themeID = "nord"
        XCTAssertNil(vm.unknownThemeID)
    }

    func testThemeIDOnDeletedHostIsIgnored() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "a", address: "a.example"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        try await vm.delete()
        vm.themeID = "nord"
        XCTAssertNil(vm.themeID)
        XCTAssertNil(vm.inheritedThemeID)
        XCTAssertNil(vm.unknownThemeID)
        XCTAssertNil(vault.get(SavedHost.self, id: host.id))
    }

    // MARK: Theme row and gallery (v0.6.1)

    func testDefaultThemeIsGroupThemeThenAppDefaultThenAutomatic() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "G", defaultThemeID: "dracula"))
        let grouped = try await vault.save(SavedHost(label: "a", address: "a.example", groupID: group.id, themeID: "nord"))
        let loose = try await vault.save(SavedHost(label: "b", address: "b.example"))
        let groupedVM = HostDetailsViewModel(vault: vault, hostID: grouped.id)
        let looseVM = HostDetailsViewModel(vault: vault, hostID: loose.id)
        XCTAssertEqual(groupedVM.defaultTheme(appDefaultThemeID: "nord")?.id, "dracula")
        XCTAssertEqual(looseVM.defaultTheme(appDefaultThemeID: "nord")?.id, "nord")
        XCTAssertNil(looseVM.defaultTheme(appDefaultThemeID: nil))
        XCTAssertNil(looseVM.defaultTheme(appDefaultThemeID: "from-the-future"))
    }

    func testDefaultThemeLabel() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "G", defaultThemeID: "dracula"))
        let grouped = try await vault.save(SavedHost(label: "a", address: "a.example", groupID: group.id))
        let loose = try await vault.save(SavedHost(label: "b", address: "b.example"))
        XCTAssertEqual(HostDetailsViewModel(vault: vault, hostID: grouped.id).defaultThemeLabel(appDefaultThemeID: "nord"),
                       "Dracula \u{2014} from group")
        let looseVM = HostDetailsViewModel(vault: vault, hostID: loose.id)
        XCTAssertEqual(looseVM.defaultThemeLabel(appDefaultThemeID: "nord"), "Nord")
        XCTAssertEqual(looseVM.defaultThemeLabel(appDefaultThemeID: nil), "Automatic")
        XCTAssertEqual(looseVM.defaultThemeLabel(appDefaultThemeID: "from-the-future"), "Automatic")
    }

    func testThemeSummaryNamesOwnThemeDefaultOrUnknown() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "G", defaultThemeID: "dracula"))
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", groupID: group.id, themeID: "nord"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.themeSummary(appDefaultThemeID: nil), "Nord")
        vm.themeID = nil
        XCTAssertEqual(vm.themeSummary(appDefaultThemeID: nil), "Default (Dracula \u{2014} from group)")
        vm.groupID = nil
        XCTAssertEqual(vm.themeSummary(appDefaultThemeID: nil), "Default (Automatic)")
        vm.themeID = "from-the-future"
        XCTAssertEqual(vm.themeSummary(appDefaultThemeID: nil), "Unknown theme (from-the-future)")
    }

    func testInheritedThemeIDIgnoresOtherHosts() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "G", defaultThemeID: "dracula"))
        _ = try await vault.save(SavedHost(label: "other", address: "o.example", groupID: group.id, themeID: "nord"))
        let host = try await vault.save(SavedHost(label: "a", address: "a.example", groupID: group.id, themeID: "flexoki-dark"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.inheritedThemeID, "dracula")
        XCTAssertEqual(vm.themeID, "flexoki-dark")
    }
}
