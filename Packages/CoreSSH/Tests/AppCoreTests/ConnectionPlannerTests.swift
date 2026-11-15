import XCTest
import CoreModels
import SSHCore
import SyncCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

@MainActor
final class ConnectionPlannerTests: XCTestCase {
    private func makeVault() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    private func key(_ type: KeyType = .ed25519, passphrase: String? = nil) -> SSHKey {
        SSHKey(label: "k", keyType: type, publicKey: "pub", privateKey: "PEM-\(type.rawValue)", passphrase: passphrase)
    }

    func testDirectPasswordHost() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "H", address: "h.example", username: "root", password: "pw"))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.hostID, host.id)
        XCTAssertEqual(plan.label, "H")
        XCTAssertEqual(plan.host, "h.example")
        XCTAssertEqual(plan.port, 22)
        XCTAssertEqual(plan.username, "root")
        guard case .password("pw") = plan.credential else { return XCTFail("\(plan.credential)") }
        XCTAssertEqual(plan.engine, .citadel)
        XCTAssertNil(plan.startupScript)
    }

    func testIdentityProvidesUsernamePasswordAndKey() async throws {
        let vault = try await makeVault()
        let pwID = try await vault.save(Identity(label: "i", username: "alice", password: "secret"))
        let k = try await vault.save(key(passphrase: "pp"))
        let keyID = try await vault.save(Identity(label: "j", username: "bob", sshKeyID: k.id))
        let h1 = try await vault.save(SavedHost(label: "1", address: "a", identityID: pwID.id))
        let h2 = try await vault.save(SavedHost(label: "2", address: "b", identityID: keyID.id))
        let p1 = try ConnectionPlanner.plan(hostID: h1.id, vault: vault)
        XCTAssertEqual(p1.username, "alice")
        guard case .password("secret") = p1.credential else { return XCTFail() }
        let p2 = try ConnectionPlanner.plan(hostID: h2.id, vault: vault)
        XCTAssertEqual(p2.username, "bob")
        guard case .privateKey(.ed25519, "PEM-ed25519", "pp") = p2.credential else { return XCTFail() }
    }

    func testGroupDefaultIdentityIsInherited() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "alice", password: "secret"))
        let parent = try await vault.save(HostGroup(name: "p", defaultIdentityID: identity.id))
        let child = try await vault.save(HostGroup(name: "c", parentID: parent.id))
        let host = try await vault.save(SavedHost(label: "H", address: "a", groupID: child.id))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "alice")
        guard case .password("secret") = plan.credential else { return XCTFail() }
    }

    func testDirectCredentialsDisableInheritance() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "alice", password: "secret"))
        let group = try await vault.save(HostGroup(name: "g", defaultIdentityID: identity.id))
        let host = try await vault.save(SavedHost(label: "H", address: "a", groupID: group.id, username: "root"))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "root")
        guard case .none = plan.credential else { return XCTFail("\(plan.credential)") }
    }

    func testExplicitIdentityWinsOverDirectUsername() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "alice", password: "secret"))
        let host = try await vault.save(SavedHost(label: "H", address: "a", username: "root", identityID: identity.id))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "alice")
        guard case .password("secret") = plan.credential else { return XCTFail("\(plan.credential)") }
    }

    func testDeletedExplicitIdentityFallsThroughToGroupDefault() async throws {
        let vault = try await makeVault()
        let gone = try await vault.save(Identity(label: "x", username: "ghost", password: "boo"))
        let def = try await vault.save(Identity(label: "d", username: "alice", password: "secret"))
        let group = try await vault.save(HostGroup(name: "g", defaultIdentityID: def.id))
        let host = try await vault.save(SavedHost(label: "H", address: "a", groupID: group.id, identityID: gone.id))
        try await vault.delete(Identity.self, id: gone.id)
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "alice")
        guard case .password("secret") = plan.credential else { return XCTFail("\(plan.credential)") }
    }

    func testDeletedExplicitIdentityFallsThroughToDirectCredentials() async throws {
        let vault = try await makeVault()
        let gone = try await vault.save(Identity(label: "x", username: "ghost", password: "boo"))
        let def = try await vault.save(Identity(label: "d", username: "alice", password: "secret"))
        let group = try await vault.save(HostGroup(name: "g", defaultIdentityID: def.id))
        let host = try await vault.save(SavedHost(label: "H", address: "a", groupID: group.id, username: "root",
                                                  identityID: gone.id, password: "pw"))
        try await vault.delete(Identity.self, id: gone.id)
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "root")
        guard case .password("pw") = plan.credential else { return XCTFail("\(plan.credential)") }
    }

    func testEmptyPasswordCountsAsNoPassword() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "alice", password: "secret"))
        let host = try await vault.save(SavedHost(label: "H", address: "a", identityID: identity.id, password: ""))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "alice")
        guard case .password("secret") = plan.credential else { return XCTFail("\(plan.credential)") }
        let bare = try await vault.save(SavedHost(label: "B", address: "b", username: "u", password: ""))
        guard case .none = try ConnectionPlanner.plan(hostID: bare.id, vault: vault).credential else { return XCTFail() }
    }

    func testMissingKeyIsTreatedAsAbsent() async throws {
        let vault = try await makeVault()
        let k = try await vault.save(key())
        let host = try await vault.save(SavedHost(label: "H", address: "a", username: "u", password: "pw", sshKeyID: k.id))
        try await vault.delete(SSHKey.self, id: k.id)
        guard case .password("pw") = try ConnectionPlanner.plan(hostID: host.id, vault: vault).credential
        else { return XCTFail() }
    }

    func testKeyWinsOverPassword() async throws {
        let vault = try await makeVault()
        let k = try await vault.save(key())
        let host = try await vault.save(SavedHost(label: "H", address: "a", username: "u", password: "pw", sshKeyID: k.id))
        guard case .privateKey(.ed25519, _, nil) = try ConnectionPlanner.plan(hostID: host.id, vault: vault).credential
        else { return XCTFail() }
    }

    func testRSAKeySelectsSystemSSH() async throws {
        let vault = try await makeVault()
        let ed = try await vault.save(key(.ed25519))
        let rsa = try await vault.save(key(.rsa))
        let h1 = try await vault.save(SavedHost(label: "1", address: "a", username: "u", sshKeyID: ed.id))
        let h2 = try await vault.save(SavedHost(label: "2", address: "b", username: "u", sshKeyID: rsa.id))
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: h1.id, vault: vault).engine, .citadel)
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: h2.id, vault: vault).engine, .systemSSH)
    }

    func testUseSystemSSHFlagSelectsSystemSSH() async throws {
        let vault = try await makeVault()
        let on = try await vault.save(SavedHost(label: "1", address: "a", username: "u", useSystemSSH: true))
        let off = try await vault.save(SavedHost(label: "2", address: "b", username: "u", useSystemSSH: false))
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: on.id, vault: vault).engine, .systemSSH)
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: off.id, vault: vault).engine, .citadel)
    }

    func testInheritedPortAndStartupSnippet() async throws {
        let vault = try await makeVault()
        let snippet = try await vault.save(Snippet(name: "s", script: "cd /srv && ls"))
        let group = try await vault.save(HostGroup(name: "g", defaultPort: 2222))
        let host = try await vault.save(SavedHost(label: "H", address: "a", groupID: group.id, username: "u",
                                                  startupSnippetID: snippet.id))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.port, 2222)
        XCTAssertEqual(plan.startupScript, "cd /srv && ls")
        try await vault.delete(Snippet.self, id: snippet.id)
        XCTAssertNil(try ConnectionPlanner.plan(hostID: host.id, vault: vault).startupScript)
    }

    func testMissingAddressOrUsernameThrows() async throws {
        let vault = try await makeVault()
        let noAddress = try await vault.save(SavedHost(label: "1", address: "  ", username: "u"))
        let noUser = try await vault.save(SavedHost(label: "2", address: "a"))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: noAddress.id, vault: vault)) {
            XCTAssertEqual($0 as? ConnectionPlanError, .missingAddress)
        }
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: noUser.id, vault: vault)) {
            XCTAssertEqual($0 as? ConnectionPlanError, .missingUsername(.host(label: "2")))
        }
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: UUID(), vault: vault)) {
            XCTAssertEqual($0 as? ConnectionPlanError, .hostNotFound)
        }
    }

    func testMissingUsernameNamesTheIdentityInEffect() async throws {
        let vault = try await makeVault()
        let emptyUser = try await vault.save(Identity(label: "NAS admin", username: "", password: "pw"))
        let explicit = try await vault.save(SavedHost(label: "NAS", address: "nas", identityID: emptyUser.id))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: explicit.id, vault: vault)) {
            XCTAssertEqual($0 as? ConnectionPlanError, .missingUsername(.identity(label: "NAS admin")))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "The identity \u{201C}NAS admin\u{201D} has no username. Add one in Keychain, or set Direct credentials on this host.")
        }
        // Inherited from the group default identity.
        let group = try await vault.save(HostGroup(name: "g", defaultIdentityID: emptyUser.id))
        let inheriting = try await vault.save(SavedHost(label: "Child", address: "c", groupID: group.id))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: inheriting.id, vault: vault)) {
            XCTAssertEqual($0 as? ConnectionPlanError, .missingUsername(.identity(label: "NAS admin")))
        }
    }

    func testMissingUsernameOnDirectCredentialsNamesTheHost() async throws {
        let vault = try await makeVault()
        let direct = try await vault.save(SavedHost(label: "Docker", address: "d", password: "pw"))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: direct.id, vault: vault)) {
            XCTAssertEqual($0 as? ConnectionPlanError, .missingUsername(.host(label: "Docker")))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "\u{201C}Docker\u{201D} has no username. Add one in Host Details.")
        }
    }

    func testMissingUsernameMessagesFallBackForEmptyLabels() async throws {
        XCTAssertEqual(ConnectionPlanError.missingUsername(.identity(label: "")).errorDescription,
                       "The identity \u{201C}Untitled identity\u{201D} has no username. Add one in Keychain, or set Direct credentials on this host.")
        XCTAssertEqual(ConnectionPlanError.missingUsername(.host(label: "  ")).errorDescription,
                       "\u{201C}Untitled host\u{201D} has no username. Add one in Host Details.")
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "", address: "a", password: "pw"))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: host.id, vault: vault)) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "\u{201C}Untitled host\u{201D} has no username. Add one in Host Details.")
        }
    }

    func testPlanErrorsHaveCantConnectTitle() async {
        let errors: [ConnectionPlanError] = [.hostNotFound, .missingAddress,
                                             .missingUsername(.host(label: "h")),
                                             .missingUsername(.identity(label: "i"))]
        for error in errors { XCTAssertEqual(error.alertTitle, "Can't connect") }
    }

    func testQuickConnectUsesDefaultUsernameAndCitadel() async {
        let bare = ConnectionPlanner.plan(quickConnect: QuickConnectTarget(username: nil, host: "h", port: nil),
                                          defaultUsername: "corylanders")
        XCTAssertEqual(bare.username, "corylanders")
        XCTAssertEqual(bare.port, 22)
        XCTAssertEqual(bare.engine, .citadel)
        XCTAssertNil(bare.hostID)
        guard case .none = bare.credential else { return XCTFail() }
        let full = ConnectionPlanner.plan(quickConnect: QuickConnectTarget(username: "bob", host: "h", port: 2200),
                                          defaultUsername: "corylanders")
        XCTAssertEqual(full.username, "bob")
        XCTAssertEqual(full.port, 2200)
    }

    func testCredentialDescriptionIsRedacted() async {
        let creds: [SSHCredential] = [.password("hunter2"),
                                      .privateKey(type: .rsa, pem: "SECRETPEM", passphrase: "hunter3")]
        for c in creds {
            for text in [c.description, c.debugDescription, "\(c)", String(reflecting: c)] {
                XCTAssertFalse(text.contains("hunter"))
                XCTAssertFalse(text.contains("SECRETPEM"))
                XCTAssertTrue(text.contains("<redacted>"))
            }
        }
    }

    func testPlanDescriptionIsRedacted() async {
        let plan = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                  credential: .privateKey(type: .ed25519, pem: "SECRETPEM", passphrase: "hunter3"),
                                  engine: .citadel, startupScript: nil)
        let pw = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                credential: .password("hunter2"), engine: .citadel, startupScript: nil)
        for p in [plan, pw] {
            for text in [String(describing: p), String(reflecting: p)] {
                XCTAssertFalse(text.contains("hunter"))
                XCTAssertFalse(text.contains("SECRETPEM"))
            }
        }
    }

    // MARK: 1Password SSH agent

    func testHostAgentKeyWinsOverKeyAndPassword() async throws {
        let vault = try await makeVault()
        let k = try await vault.save(key())
        let choice = AgentKeyChoice(publicKey: "ssh-ed25519 AAAA pinned")
        let host = try await vault.save(SavedHost(label: "H", address: "a", username: "root", password: "pw",
                                                  sshKeyID: k.id, agentKey: choice))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.agentKey, choice)
        guard case .none = plan.credential else { return XCTFail("\(plan.credential)") }
        XCTAssertEqual(plan.engine, .systemSSH)
        XCTAssertEqual(plan.username, "root")
    }

    func testPlansWithoutAgentKeyHaveNone() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "H", address: "a", username: "root", password: "pw"))
        XCTAssertNil(try ConnectionPlanner.plan(hostID: host.id, vault: vault).agentKey)
        XCTAssertNil(ConnectionPlanner.plan(quickConnect: QuickConnectTarget(username: nil, host: "h", port: nil),
                                            defaultUsername: "me").agentKey)
    }

    func testIdentityAgentKeyWinsWithinTheIdentity() async throws {
        let vault = try await makeVault()
        let k = try await vault.save(key())
        let identity = try await vault.save(Identity(label: "i", username: "alice", password: "secret", sshKeyID: k.id,
                                                     agentKey: AgentKeyChoice(publicKey: nil)))
        let host = try await vault.save(SavedHost(label: "H", address: "a", identityID: identity.id))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertEqual(plan.username, "alice")
        XCTAssertEqual(plan.engine, .systemSSH)
    }

    func testSourceOrderIsUnchangedByAgentKeys() async throws {
        let vault = try await makeVault()
        // An explicit identity without an agent key beats the host's own agent key.
        let identity = try await vault.save(Identity(label: "i", username: "alice", password: "secret"))
        let host = try await vault.save(SavedHost(label: "H", address: "a", username: "root", identityID: identity.id,
                                                  agentKey: AgentKeyChoice(publicKey: nil)))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertNil(plan.agentKey)
        guard case .password("secret") = plan.credential else { return XCTFail("\(plan.credential)") }

        // A host whose only direct credential is an agent key doesn't inherit the group's identity...
        let groupIdentity = try await vault.save(Identity(label: "g", username: "bob", password: "pw2"))
        let group = try await vault.save(HostGroup(name: "g", defaultIdentityID: groupIdentity.id))
        let agentOnly = try await vault.save(SavedHost(label: "A", address: "a", groupID: group.id,
                                                       agentKey: AgentKeyChoice(publicKey: nil)))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: agentOnly.id, vault: vault)) { error in
            XCTAssertEqual(error as? ConnectionPlanError, .missingUsername(.host(label: "A")))
        }

        // ...while a group identity's agent key is inherited.
        let agentIdentity = try await vault.save(Identity(label: "ag", username: "carol",
                                                          agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 AAAA")))
        let agentGroup = try await vault.save(HostGroup(name: "ag", defaultIdentityID: agentIdentity.id))
        let inheriting = try await vault.save(SavedHost(label: "I", address: "a", groupID: agentGroup.id))
        let inherited = try ConnectionPlanner.plan(hostID: inheriting.id, vault: vault)
        XCTAssertEqual(inherited.agentKey, AgentKeyChoice(publicKey: "ssh-ed25519 AAAA"))
        XCTAssertEqual(inherited.username, "carol")
    }

    func testKeyShadowedByAgentKeyIsNotCountedAsUsed() async throws {
        let vault = try await makeVault()
        let k = try await vault.save(key())
        _ = try await vault.save(SavedHost(label: "H", address: "a", username: "root", sshKeyID: k.id,
                                           agentKey: AgentKeyChoice(publicKey: nil)))
        let resolved = CredentialResolution.resolve(host: vault.all(SavedHost.self)[0],
                                                    directory: HostDirectory(hosts: vault.all(SavedHost.self), groups: []),
                                                    vault: vault)
        XCTAssertEqual(resolved.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertNil(resolved.key)
        XCTAssertNil(resolved.password)
    }

    // MARK: prefersIdentity

    func testIdentityModeHostWithKeptUsernameUsesTheGroupDefaultIdentity() async throws {
        let vault = try await makeVault()
        let groupIdentity = try await vault.save(Identity(label: "g", username: "groupUser", password: "groupPW"))
        let group = try await vault.save(HostGroup(name: "G", defaultIdentityID: groupIdentity.id))
        let host = try await vault.save(SavedHost(label: "H", address: "h", groupID: group.id, username: "root",
                                                  password: "ownPW", prefersIdentity: true))
        let plan = try ConnectionPlanner.plan(hostID: host.id, vault: vault)
        XCTAssertEqual(plan.username, "groupUser")
        guard case .password("groupPW") = plan.credential else { return XCTFail("\(plan.credential)") }
    }

    func testPublicCredentialResolutionReturnsTheGroupIdentitysUsernameAndAgentKey() async throws {
        let vault = try await makeVault()
        let choice = AgentKeyChoice(publicKey: nil)
        let identity = try await vault.save(Identity(label: "g", username: "groupUser", agentKey: choice))
        let group = try await vault.save(HostGroup(name: "G", defaultIdentityID: identity.id))
        let host = try await vault.save(SavedHost(label: "H", address: "h", groupID: group.id, username: "root",
                                                  prefersIdentity: true))
        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        let resolved = CredentialResolution.resolve(host: host, directory: directory, vault: vault)
        XCTAssertEqual(resolved.username, "groupUser")
        XCTAssertEqual(resolved.agentKey, choice)
        XCTAssertEqual(resolved.identity?.id, identity.id)
    }

    func testIdentityModeHostWithoutAnyIdentityReportsIdentityNotChosen() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "Box", address: "h", username: "root", prefersIdentity: true))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: host.id, vault: vault)) { error in
            XCTAssertEqual(error.localizedDescription,
                           "\u{201C}Box\u{201D} is set to use an identity, but none is chosen. Choose an identity in Host Details.")
        }
        let blank = try await vault.save(SavedHost(label: "  ", address: "h", prefersIdentity: true))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: blank.id, vault: vault)) { error in
            XCTAssertEqual(error.localizedDescription,
                           "\u{201C}Untitled host\u{201D} is set to use an identity, but none is chosen. Choose an identity in Host Details.")
        }
    }

    func testIdentityModeHostWithADeletedIdentityReportsIdentityNotChosen() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "Box", address: "h", identityID: UUID(), prefersIdentity: true))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: host.id, vault: vault)) { error in
            XCTAssertEqual(error as? ConnectionPlanError, .identityNotChosen(hostLabel: "Box"))
        }
    }

    func testIdentityModeHostWithoutAGroupDefaultIgnoresItsOwnFields() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "H", address: "h", username: "root", password: "pw",
                                                  prefersIdentity: true))
        XCTAssertThrowsError(try ConnectionPlanner.plan(hostID: host.id, vault: vault),
                             "no identity is in effect, and the kept username isn't used")
    }

    func testExplicitIdentityStillWinsOverPrefersIdentity() async throws {
        let vault = try await makeVault()
        let groupIdentity = try await vault.save(Identity(label: "g", username: "groupUser"))
        let explicit = try await vault.save(Identity(label: "e", username: "explicitUser", password: "e"))
        let group = try await vault.save(HostGroup(name: "G", defaultIdentityID: groupIdentity.id))
        let host = try await vault.save(SavedHost(label: "H", address: "h", groupID: group.id, username: "root",
                                                  identityID: explicit.id, prefersIdentity: true))
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: host.id, vault: vault).username, "explicitUser")
        try await vault.deleteIdentity(id: explicit.id)
        XCTAssertEqual(try ConnectionPlanner.plan(hostID: host.id, vault: vault).username, "groupUser",
                       "a dead explicit identity falls back to the group default, not the kept username")
    }

    func testPrefersDirectAndLegacyUseTheHostsOwnFields() async throws {
        let vault = try await makeVault()
        let groupIdentity = try await vault.save(Identity(label: "g", username: "groupUser"))
        let group = try await vault.save(HostGroup(name: "G", defaultIdentityID: groupIdentity.id))
        for preference in [false, nil] as [Bool?] {
            let host = try await vault.save(SavedHost(label: "H", address: "h", groupID: group.id, username: "root",
                                                      prefersIdentity: preference))
            XCTAssertEqual(try ConnectionPlanner.plan(hostID: host.id, vault: vault).username, "root")
            let bare = try await vault.save(SavedHost(label: "B", address: "b", groupID: group.id,
                                                      prefersIdentity: preference))
            XCTAssertEqual(try ConnectionPlanner.plan(hostID: bare.id, vault: vault).username, "groupUser")
        }
    }
}
