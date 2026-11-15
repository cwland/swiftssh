import XCTest
import CoreModels
@testable import AppCore

/// v0.10 step 1: a click only selects; the pencil (or Edit) opens Host Details or the group panel;
/// right-click actions (duplicate, move, remove, new host in group); a group's parent can change.
@MainActor
final class HostsCardActionsTests: XCTestCase {
    private var vault: LocalVault!

    private func makeModel() async throws -> HostsViewModel {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
        return HostsViewModel(vault: vault)
    }

    private func host(_ label: String, in group: UUID? = nil) async throws -> SavedHost {
        try await vault.save(SavedHost(label: label, address: label, groupID: group, username: "u"))
    }

    // MARK: Select vs edit

    func testAClickSelectsWithoutOpeningDetails() async throws {
        let vm = try await makeModel()
        let a = try await host("a")
        vm.click(hostID: a.id, modifier: .none)
        XCTAssertEqual(vm.selectedHostIDs, [a.id])
        XCTAssertNil(vm.editingHostID)
        XCTAssertNil(vm.editingHost)
    }

    func testEditOpensDetailsAndSelectsTheHost() async throws {
        let vm = try await makeModel()
        let a = try await host("a")
        let b = try await host("b")
        vm.click(hostID: b.id, modifier: .none)
        vm.edit(hostID: a.id)
        XCTAssertEqual(vm.editingHostID, a.id)
        XCTAssertEqual(vm.editingHost?.id, a.id)
        XCTAssertEqual(vm.selectedHostIDs, [a.id])
        // Another click leaves the open panel alone.
        vm.click(hostID: b.id, modifier: .none)
        XCTAssertEqual(vm.editingHostID, a.id)
        vm.closeEditor()
        XCTAssertNil(vm.editingHostID)
        XCTAssertEqual(vm.selectedHostIDs, [b.id], "closing the panel keeps the selection")
    }

    func testEditingAGroupClosesHostDetailsAndTheOtherWayRound() async throws {
        let vm = try await makeModel()
        let g = try await vault.save(HostGroup(name: "G"))
        let a = try await host("a")
        vm.edit(hostID: a.id)
        vm.edit(groupID: g.id)
        XCTAssertNil(vm.editingHostID)
        XCTAssertEqual(vm.editingGroupID, g.id)
        XCTAssertEqual(vm.editingGroup?.name, "G")
        vm.edit(hostID: a.id)
        XCTAssertNil(vm.editingGroupID)
        XCTAssertEqual(vm.editingHostID, a.id)
    }

    func testNewHostOpensItsDetails() async throws {
        let vm = try await makeModel()
        let new = try await vm.newHost()
        XCTAssertEqual(vm.editingHostID, new.id)
    }

    func testSelectingAGroupClearsTheHostSelection() async throws {
        let vm = try await makeModel()
        let g = try await vault.save(HostGroup(name: "G"))
        let a = try await host("a")
        vm.click(hostID: a.id, modifier: .none)
        vm.select(groupID: g.id)
        XCTAssertEqual(vm.selectedGroupID, g.id)
        XCTAssertTrue(vm.selectedHostIDs.isEmpty)
        vm.click(hostID: a.id, modifier: .none)
        XCTAssertNil(vm.selectedGroupID)
    }

    func testClearSelectionDeselectsHostsAndGroupsButKeepsAnOpenPanel() async throws {
        let vm = try await makeModel()
        let g = try await vault.save(HostGroup(name: "G"))
        let a = try await host("a")
        vm.edit(hostID: a.id)
        vm.clearSelection()
        XCTAssertTrue(vm.selectedHostIDs.isEmpty)
        XCTAssertEqual(vm.editingHostID, a.id)
        vm.select(groupID: g.id)
        vm.clearSelection()
        XCTAssertNil(vm.selectedGroupID)
    }

    func testADeletedHostClosesItsPanel() async throws {
        let vm = try await makeModel()
        let a = try await host("a")
        vm.edit(hostID: a.id)
        try await vm.removeHosts([a.id])
        XCTAssertNil(vm.editingHost)
        XCTAssertNil(vm.editingHostID)
        XCTAssertTrue(vm.selectedHostIDs.isEmpty)
    }

    // MARK: Which hosts a right-click acts on

    func testContextMenuActsOnTheSelectionWhenTheClickedHostIsInIt() async throws {
        let vm = try await makeModel()
        let a = try await host("a"), b = try await host("b"), c = try await host("c")
        vm.click(hostID: a.id, modifier: .none)
        vm.click(hostID: c.id, modifier: .toggle)
        XCTAssertEqual(vm.hostIDs(forContextMenuOn: c.id), [a.id, c.id])
        XCTAssertEqual(vm.hostIDs(forContextMenuOn: b.id), [b.id], "a card outside the selection: just it")
    }

    // MARK: Duplicate, move, remove

    func testDuplicateCopiesEverythingButTheIdAndAddsCopyToTheLabel() async throws {
        let vm = try await makeModel()
        let g = try await vault.save(HostGroup(name: "G"))
        var original = SavedHost(label: "web", address: "10.0.0.1", groupID: g.id, username: "root")
        original.port = 2222
        original.password = "pw"
        original.tags = ["prod"]
        original.themeID = "dracula"
        original = try await vault.save(original)
        let copy = try await vm.duplicateHost(id: original.id)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.label, "web copy")
        XCTAssertEqual(copy.address, "10.0.0.1")
        XCTAssertEqual(copy.username, "root")
        XCTAssertEqual(copy.port, 2222)
        XCTAssertEqual(copy.password, "pw")
        XCTAssertEqual(copy.groupID, g.id)
        XCTAssertEqual(copy.tags, ["prod"])
        XCTAssertEqual(copy.themeID, "dracula")
        XCTAssertEqual(vault.all(SavedHost.self).count, 2)
        XCTAssertEqual(vm.selectedHostIDs, [copy.id], "the copy is selected")
    }

    func testMoveHostsToAGroupAndBackToTheTop() async throws {
        let vm = try await makeModel()
        let g = try await vault.save(HostGroup(name: "G"))
        let a = try await host("a"), b = try await host("b")
        try await vm.moveHosts([a.id, b.id], toGroup: g.id)
        XCTAssertEqual(vault.get(SavedHost.self, id: a.id)?.groupID, g.id)
        XCTAssertEqual(vault.get(SavedHost.self, id: b.id)?.groupID, g.id)
        try await vm.moveHosts([a.id], toGroup: nil)
        XCTAssertNil(vault.get(SavedHost.self, id: a.id)?.groupID)
    }

    func testRemoveHostsDeletesThem() async throws {
        let vm = try await makeModel()
        let a = try await host("a"), b = try await host("b"), c = try await host("c")
        vm.click(hostID: a.id, modifier: .none)
        vm.click(hostID: b.id, modifier: .toggle)
        try await vm.removeHosts([a.id, b.id])
        XCTAssertEqual(vault.all(SavedHost.self).map(\.id), [c.id])
        XCTAssertTrue(vm.selectedHostIDs.isEmpty)
    }

    func testNewHostInGroupCreatesItThereAndOpensItsDetails() async throws {
        let vm = try await makeModel()
        let g = try await vault.save(HostGroup(name: "G"))
        let new = try await vm.newHost(inGroup: g.id)
        XCTAssertEqual(new.groupID, g.id)
        XCTAssertEqual(vm.editingHostID, new.id)
    }

    // MARK: Group destinations and parent

    func testGroupDestinationsListEveryGroupByPathInOrder() async throws {
        let vm = try await makeModel()
        let prod = try await vault.save(HostGroup(name: "Prod"))
        let web = try await vault.save(HostGroup(name: "Web", parentID: prod.id))
        let dev = try await vault.save(HostGroup(name: "dev"))
        let dests = vm.groupDestinations()
        XCTAssertEqual(dests.map(\.name), ["dev", "Prod", "Prod \u{203A} Web"])
        XCTAssertEqual(dests.map(\.id), [dev.id, prod.id, web.id])
        // A group can't move into itself or below itself.
        XCTAssertEqual(vm.groupDestinations(excludingSubtreeOf: prod.id).map(\.id), [dev.id])
    }

    func testMoveGroupChangesItsParentAndRefusesACycle() async throws {
        let vm = try await makeModel()
        let prod = try await vault.save(HostGroup(name: "Prod"))
        let web = try await vault.save(HostGroup(name: "Web", parentID: prod.id))
        let dev = try await vault.save(HostGroup(name: "dev"))
        try await vm.moveGroup(id: web.id, toParent: dev.id)
        XCTAssertEqual(vault.get(HostGroup.self, id: web.id)?.parentID, dev.id)
        try await vm.moveGroup(id: web.id, toParent: nil)
        XCTAssertNil(vault.get(HostGroup.self, id: web.id)?.parentID)
        try await vm.moveGroup(id: web.id, toParent: prod.id)
        do {
            try await vm.moveGroup(id: prod.id, toParent: web.id)
            XCTFail("moving a group below itself must throw")
        } catch {
            XCTAssertEqual(error as? HostsError, .groupCycle)
        }
        do {
            try await vm.moveGroup(id: prod.id, toParent: prod.id)
            XCTFail("a group can't be its own parent")
        } catch {
            XCTAssertEqual(error as? HostsError, .groupCycle)
        }
        XCTAssertNil(vault.get(HostGroup.self, id: prod.id)?.parentID)
    }

    func testDeletingTheEditedGroupClosesItsPanel() async throws {
        let vm = try await makeModel()
        let g = try await vault.save(HostGroup(name: "G"))
        vm.edit(groupID: g.id)
        try await vm.deleteGroup(id: g.id)
        XCTAssertNil(vm.editingGroup)
        XCTAssertNil(vm.editingGroupID)
    }
}
