import XCTest
import Observation
import CoreModels
@testable import AppCore

@MainActor
final class HostsViewModelTests: XCTestCase {
    private func makeVault() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    @MainActor func testVisibleHostsIncludesDescendantGroupsAndSortsByLabel() async throws {
        let vault = try await makeVault()
        let parent = try await vault.save(HostGroup(name: "Prod"))
        let child = try await vault.save(HostGroup(name: "Web", parentID: parent.id))
        try await vault.save(SavedHost(label: "zeta", address: "z", groupID: parent.id))
        try await vault.save(SavedHost(label: "Alpha", address: "a", groupID: child.id))
        try await vault.save(SavedHost(label: "beta", address: "b", groupID: child.id))
        try await vault.save(SavedHost(label: "outside", address: "o"))
        let vm = HostsViewModel(vault: vault)
        XCTAssertEqual(vm.visibleHosts.count, 4)
        vm.openGroup(parent.id)
        XCTAssertEqual(vm.visibleHosts.map(\.label), ["Alpha", "beta", "zeta"])
        XCTAssertEqual(vm.hostCount(in: parent), 3)
        XCTAssertEqual(vm.hostCount(in: child), 2)
    }

    @MainActor func testVisibleGroupsAreDirectChildrenAndHiddenWhileSearching() async throws {
        let vault = try await makeVault()
        let root = try await vault.save(HostGroup(name: "Root"))
        let child = try await vault.save(HostGroup(name: "Child", parentID: root.id))
        try await vault.save(HostGroup(name: "Grandchild", parentID: child.id))
        let vm = HostsViewModel(vault: vault)
        XCTAssertEqual(vm.visibleGroups.map(\.name), ["Root"])
        vm.openGroup(root.id)
        XCTAssertEqual(vm.visibleGroups.map(\.name), ["Child"])
        vm.searchText = "x"
        XCTAssertTrue(vm.visibleGroups.isEmpty)
        vm.searchText = ""
        vm.selectedTags = ["t"]
        XCTAssertTrue(vm.visibleGroups.isEmpty)
    }

    @MainActor func testBreadcrumbsFollowParentChain() async throws {
        let vault = try await makeVault()
        let a = try await vault.save(HostGroup(name: "A"))
        let b = try await vault.save(HostGroup(name: "B", parentID: a.id))
        let c = try await vault.save(HostGroup(name: "C", parentID: b.id))
        let vm = HostsViewModel(vault: vault)
        XCTAssertTrue(vm.breadcrumbs.isEmpty)
        vm.openGroup(c.id)
        XCTAssertEqual(vm.breadcrumbs.map(\.name), ["A", "B", "C"])
    }

    @MainActor func testSearchAndTagFilterCombine() async throws {
        let vault = try await makeVault()
        try await vault.save(SavedHost(label: "web1", address: "10.0.0.1", tags: ["prod", "web"]))
        try await vault.save(SavedHost(label: "web2", address: "10.0.0.2", tags: ["dev", "web"]))
        try await vault.save(SavedHost(label: "db1", address: "10.0.0.3", tags: ["prod"], username: "admin"))
        let vm = HostsViewModel(vault: vault)
        vm.selectedTags = ["prod", "web"]
        XCTAssertEqual(vm.visibleHosts.map(\.label), ["web1"])
        vm.selectedTags = ["web"]
        vm.searchText = "WEB2"
        XCTAssertEqual(vm.visibleHosts.map(\.label), ["web2"])
        vm.selectedTags = []
        vm.searchText = "admin"
        XCTAssertEqual(vm.visibleHosts.map(\.label), ["db1"])
        vm.searchText = "10.0.0"
        XCTAssertEqual(vm.visibleHosts.count, 3)
    }

    @MainActor func testSubtitleNamesTheUserTheConnectionUses() async throws {
        let vault = try await makeVault()
        let hostIdentity = try await vault.save(Identity(label: "i1", username: "idUser"))
        let groupIdentity = try await vault.save(Identity(label: "i2", username: "groupUser"))
        let group = try await vault.save(HostGroup(name: "G", defaultIdentityID: groupIdentity.id))
        // An explicit identity wins over the host's own username.
        let explicitWins = try await vault.save(SavedHost(label: "e", address: "e", username: "direct",
                                                          identityID: hostIdentity.id))
        let direct = try await vault.save(SavedHost(label: "d", address: "d", groupID: group.id, username: "direct"))
        let viaIdentity = try await vault.save(SavedHost(label: "i", address: "i", identityID: hostIdentity.id))
        let viaGroup = try await vault.save(SavedHost(label: "g", address: "g", groupID: group.id))
        // A host with its own password uses its own fields, so the group identity's user is not used.
        let ownPasswordOnly = try await vault.save(SavedHost(label: "p", address: "p", groupID: group.id,
                                                             password: "pw"))
        let none = try await vault.save(SavedHost(label: "n", address: "n"))
        let vm = HostsViewModel(vault: vault)
        XCTAssertEqual(vm.subtitle(for: explicitWins), "ssh, idUser")
        XCTAssertEqual(vm.subtitle(for: direct), "ssh, direct")
        XCTAssertEqual(vm.subtitle(for: viaIdentity), "ssh, idUser")
        XCTAssertEqual(vm.subtitle(for: viaGroup), "ssh, groupUser")
        XCTAssertEqual(vm.subtitle(for: ownPasswordOnly), "ssh")
        XCTAssertEqual(vm.subtitle(for: none), "ssh")
    }

    @MainActor func testNewHostIsCreatedInCurrentGroupAndSelected() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "G"))
        let vm = HostsViewModel(vault: vault)
        vm.openGroup(group.id)
        let host = try await vm.newHost()
        XCTAssertEqual(host.label, "New host")
        XCTAssertEqual(host.groupID, group.id)
        XCTAssertEqual(vm.selectedHostID, host.id)
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.groupID, group.id)
    }

    @MainActor func testNewGroupIsChildOfCurrentGroup() async throws {
        let vault = try await makeVault()
        let parent = try await vault.save(HostGroup(name: "P"))
        let vm = HostsViewModel(vault: vault)
        let top = try await vm.newGroup(name: "Top")
        XCTAssertNil(top.parentID)
        vm.openGroup(parent.id)
        let child = try await vm.newGroup(name: "Kid")
        XCTAssertEqual(child.parentID, parent.id)
        XCTAssertEqual(child.name, "Kid")
    }

    @MainActor func testQuickConnectTargetParsedFromSearchText() async throws {
        let vm = HostsViewModel(vault: try await makeVault())
        XCTAssertNil(vm.quickConnectTarget)
        vm.searchText = "ssh root@example.com:2222"
        XCTAssertEqual(vm.quickConnectTarget, QuickConnectTarget(username: "root", host: "example.com", port: 2222))
    }

    @MainActor func testCanConnectOnlyWithAQuickConnectTarget() async throws {
        let vm = HostsViewModel(vault: try await makeVault())
        XCTAssertFalse(vm.canConnect)
        vm.searchText = "root@example.com"
        XCTAssertTrue(vm.canConnect)
        vm.searchText = "ssh -x"
        XCTAssertFalse(vm.canConnect)
    }

    @MainActor func testAllTagsSortedAndUnique() async throws {
        let vault = try await makeVault()
        try await vault.save(SavedHost(label: "a", address: "a", tags: ["web", "prod"]))
        try await vault.save(SavedHost(label: "b", address: "b", tags: ["dev", "web"]))
        let gone = try await vault.save(SavedHost(label: "c", address: "c", tags: ["zzz"]))
        try await vault.delete(SavedHost.self, id: gone.id)
        let vm = HostsViewModel(vault: vault)
        XCTAssertEqual(vm.allTags, ["dev", "prod", "web"])
    }

    @MainActor func testDeletedCurrentGroupFallsBackToRoot() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "G"))
        let vm = HostsViewModel(vault: vault)
        vm.openGroup(group.id)
        XCTAssertEqual(vm.effectiveGroupID, group.id)
        try await vault.deleteGroup(id: group.id)
        XCTAssertNil(vm.effectiveGroupID)
        XCTAssertTrue(vm.breadcrumbs.isEmpty)
        let host = try await vm.newHost()
        XCTAssertNil(host.groupID)
        let sub = try await vm.newGroup(name: "S")
        XCTAssertNil(sub.parentID)
        XCTAssertEqual(vm.visibleGroups.map(\.name), ["S"])
    }

    @MainActor func testSelectedHostIsNilAfterDeletion() async throws {
        let vault = try await makeVault()
        let vm = HostsViewModel(vault: vault)
        XCTAssertNil(vm.selectedHost)
        let host = try await vm.newHost()
        XCTAssertEqual(vm.selectedHost?.id, host.id)
        try await vault.delete(SavedHost.self, id: host.id)
        XCTAssertNil(vm.selectedHost)
    }

    @MainActor func testBreadcrumbsTerminateOnCyclicParents() async throws {
        let vault = try await makeVault()
        let a = try await vault.save(HostGroup(name: "A"))
        let b = try await vault.save(HostGroup(name: "B", parentID: a.id))
        var a2 = a
        a2.parentID = b.id
        try await vault.save(a2)
        let vm = HostsViewModel(vault: vault)
        vm.openGroup(a.id)
        XCTAssertEqual(Set(vm.breadcrumbs.map(\.name)), ["A", "B"])
    }

    @MainActor func testEmptyUsernameIsTreatedAsMissing() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "i", username: "idUser"))
        let host = try await vault.save(SavedHost(label: "h", address: "h", username: "", identityID: identity.id))
        let vm = HostsViewModel(vault: vault)
        XCTAssertEqual(vm.subtitle(for: host), "ssh, idUser")
    }

    @MainActor func testObservationFiresOnVisibleHostsAfterSave() async throws {
        let vault = try await makeVault()
        let vm = HostsViewModel(vault: vault)
        let fired = Fired()
        withObservationTracking({ _ = vm.visibleHosts }, onChange: { fired.value = true })
        XCTAssertFalse(fired.value)
        try await vault.save(SavedHost(label: "x", address: "x"))
        XCTAssertTrue(fired.value)
    }

    @MainActor func testRenameGroupTrimsAndSaves() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "Old"))
        let vm = HostsViewModel(vault: vault)
        try await vm.renameGroup(id: group.id, name: "  New name \n")
        XCTAssertEqual(vault.get(HostGroup.self, id: group.id)?.name, "New name")
    }

    @MainActor func testRenameGroupRejectsEmptyName() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "Old"))
        let vm = HostsViewModel(vault: vault)
        do {
            try await vm.renameGroup(id: group.id, name: "   ")
            XCTFail("expected HostsError.emptyGroupName")
        } catch let error as HostsError {
            XCTAssertEqual(error, .emptyGroupName)
            XCTAssertEqual(error.localizedDescription, "A group name can't be empty.")
        }
        XCTAssertEqual(vault.get(HostGroup.self, id: group.id)?.name, "Old")
    }

    @MainActor func testRenameMissingGroupDoesNothing() async throws {
        let vault = try await makeVault()
        let vm = HostsViewModel(vault: vault)
        try await vm.renameGroup(id: UUID(), name: "x")
        XCTAssertTrue(vault.all(HostGroup.self).isEmpty)
    }

    @MainActor func testDeleteGroupMovesHostsAndSubgroupsUpOneLevel() async throws {
        let vault = try await makeVault()
        let parent = try await vault.save(HostGroup(name: "Parent"))
        let group = try await vault.save(HostGroup(name: "Doomed", parentID: parent.id))
        let child = try await vault.save(HostGroup(name: "Child", parentID: group.id))
        let host = try await vault.save(SavedHost(label: "h", address: "h", groupID: group.id))
        let vm = HostsViewModel(vault: vault)
        try await vm.deleteGroup(id: group.id)
        XCTAssertNil(vault.get(HostGroup.self, id: group.id))
        XCTAssertEqual(vault.get(HostGroup.self, id: child.id)?.parentID, parent.id)
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.groupID, parent.id)
    }
}

private final class Fired: @unchecked Sendable { var value = false }
