import XCTest
import CoreModels
import SyncCore
@testable import AppCore

private typealias Host = CoreModels.Host

@MainActor
final class VaultOperationsTests: XCTestCase {
    private func open() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    func testDeleteGroupReparentsHostsAndSubgroups() async throws {
        let vault = try await open()
        let top = try await vault.save(HostGroup(name: "top"))
        let mid = try await vault.save(HostGroup(name: "mid", parentID: top.id))
        let sub = try await vault.save(HostGroup(name: "sub", parentID: mid.id))
        let host = try await vault.save(Host(label: "h", address: "h", groupID: mid.id))
        try await vault.deleteGroup(id: mid.id)
        XCTAssertNil(vault.get(HostGroup.self, id: mid.id))
        XCTAssertEqual(vault.get(HostGroup.self, id: sub.id)?.parentID, top.id)
        XCTAssertEqual(vault.get(Host.self, id: host.id)?.groupID, top.id)
    }

    func testDeleteRootGroupMovesChildrenToRoot() async throws {
        let vault = try await open()
        let g = try await vault.save(HostGroup(name: "g"))
        let host = try await vault.save(Host(label: "h", address: "h", groupID: g.id))
        try await vault.deleteGroup(id: g.id)
        XCTAssertNil(vault.get(Host.self, id: host.id)?.groupID)
    }

    func testDeleteIdentityClearsHostAndGroupReferences() async throws {
        let vault = try await open()
        let ident = try await vault.save(Identity(label: "i", username: "u"))
        let host = try await vault.save(Host(label: "h", address: "h", identityID: ident.id))
        let group = try await vault.save(HostGroup(name: "g", defaultIdentityID: ident.id))
        try await vault.deleteIdentity(id: ident.id)
        XCTAssertNil(vault.get(Identity.self, id: ident.id))
        XCTAssertNil(vault.get(Host.self, id: host.id)?.identityID)
        XCTAssertNil(vault.get(HostGroup.self, id: group.id)?.defaultIdentityID)
    }

    func testDeleteKeyClearsHostAndIdentityReferences() async throws {
        let vault = try await open()
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv"))
        let host = try await vault.save(Host(label: "h", address: "h", sshKeyID: key.id))
        let ident = try await vault.save(Identity(label: "i", username: "u", sshKeyID: key.id))
        try await vault.deleteSSHKey(id: key.id)
        XCTAssertNil(vault.get(SSHKey.self, id: key.id))
        XCTAssertNil(vault.get(Host.self, id: host.id)?.sshKeyID)
        XCTAssertNil(vault.get(Identity.self, id: ident.id)?.sshKeyID)
    }

    func testUsageQueriesIgnoreDeletedRecords() async throws {
        let vault = try await open()
        let key = try await vault.save(SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv"))
        let ident = try await vault.save(Identity(label: "i", username: "u", sshKeyID: key.id))
        let live = try await vault.save(Host(label: "live", address: "a", identityID: ident.id, sshKeyID: key.id))
        let gone = try await vault.save(Host(label: "gone", address: "b", identityID: ident.id, sshKeyID: key.id))
        let group = try await vault.save(HostGroup(name: "g", defaultIdentityID: ident.id))
        XCTAssertEqual(vault.hostsUsing(identityID: ident.id).count, 2)
        XCTAssertEqual(vault.groupsUsing(identityID: ident.id).map(\.id), [group.id])
        XCTAssertEqual(vault.identitiesUsing(sshKeyID: key.id).map(\.id), [ident.id])
        try await vault.delete(Host.self, id: gone.id)
        try await vault.delete(HostGroup.self, id: group.id)
        XCTAssertEqual(vault.hostsUsing(identityID: ident.id).map(\.id), [live.id])
        XCTAssertEqual(vault.hostsUsing(sshKeyID: key.id).map(\.id), [live.id])
        XCTAssertTrue(vault.groupsUsing(identityID: ident.id).isEmpty)
        try await vault.delete(Identity.self, id: ident.id)
        XCTAssertTrue(vault.identitiesUsing(sshKeyID: key.id).isEmpty)
    }

    nonisolated func testCredentialReuseGroupsMatchingUsernameAndPassword() {
        let ident = UUID()
        let same = (0..<3).map { Host(label: "a\($0)", address: "a\($0)", username: "cory", password: "pw1") }
        let other = Host(label: "b", address: "b", username: "cory", password: "pw2")
        let withIdentity = (0..<2).map { Host(label: "c\($0)", address: "c\($0)", username: "cory", identityID: ident, password: "pw1") }
        let groups = CredentialReuse.groups(in: same + [other] + withIdentity)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.map(\.id), same.map(\.id))
    }

    nonisolated func testCredentialReuseSkipsHostsThatLogInWithTheAgent() {
        // An agent host keeps its old password (switching back restores it), but it doesn't log in with it.
        let password = (0..<2).map { Host(label: "p\($0)", address: "p", username: "cory", password: "pw") }
        let agent = Host(label: "a", address: "a", username: "cory", password: "pw", agentKey: AgentKeyChoice(publicKey: nil))
        let groups = CredentialReuse.groups(in: password + [agent])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [password.map(\.id)])
        XCTAssertTrue(CredentialReuse.groups(in: [password[0], agent]).isEmpty)
    }

    nonisolated func testCredentialReuseIgnoresEmptyAndSortsLargestFirst() {
        let small = (0..<2).map { Host(label: "s\($0)", address: "s", username: "x", password: "p1") }
        let big = (0..<3).map { Host(label: "g\($0)", address: "g", username: "y", password: "p2") }
        let empty = (0..<2).map { Host(label: "e\($0)", address: "e", username: "", password: "") }
        let groups = CredentialReuse.groups(in: small + empty + big)
        XCTAssertEqual(groups.map(\.count), [3, 2])
    }

    func testCredentialReuseLeavesOutIdentityModeHosts() async {
        let a = CoreModels.Host(label: "a", address: "a", username: "cory", password: "pw")
        let b = CoreModels.Host(label: "b", address: "b", username: "cory", password: "pw")
        let c = CoreModels.Host(label: "c", address: "c", username: "cory", password: "pw", prefersIdentity: true)
        XCTAssertEqual(CredentialReuse.groups(in: [a, b, c]).map { $0.map(\.label) }, [["a", "b"]])
        XCTAssertEqual(CredentialReuse.groups(in: [a, c]), [])
    }
}
