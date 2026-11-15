import XCTest
import CoreModels
@testable import AppCore

/// Hosts screen multi-select (v0.9.0 workspaces): ⌘-click toggles, ⇧-click selects a range in the
/// visible order, a plain click selects one host (and opens Host Details as before).
@MainActor
final class HostsMultiSelectTests: XCTestCase {
    private func makeModel() async throws -> (HostsViewModel, [SavedHost]) {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
        var hosts: [SavedHost] = []
        for label in ["a", "b", "c", "d", "e"] {
            hosts.append(try await vault.save(SavedHost(label: label, address: label, username: "u")))
        }
        return (HostsViewModel(vault: vault), hosts)
    }

    func testPlainClickSelectsOneHostAndOpensDetails() async throws {
        let (vm, h) = try await makeModel()
        vm.click(hostID: h[1].id, modifier: .none)
        XCTAssertEqual(vm.selectedHostIDs, [h[1].id])
        XCTAssertEqual(vm.selectedHostID, h[1].id)
        vm.click(hostID: h[3].id, modifier: .none)
        XCTAssertEqual(vm.selectedHostIDs, [h[3].id])
        XCTAssertEqual(vm.selectedHostID, h[3].id)
    }

    func testCommandClickTogglesAndClosesDetailsWhileSeveralAreSelected() async throws {
        let (vm, h) = try await makeModel()
        vm.click(hostID: h[0].id, modifier: .none)
        vm.click(hostID: h[2].id, modifier: .toggle)
        XCTAssertEqual(vm.selectedHostIDs, [h[0].id, h[2].id])
        XCTAssertNil(vm.selectedHostID, "Host Details closes while several hosts are selected")
        vm.click(hostID: h[4].id, modifier: .toggle)
        XCTAssertEqual(vm.selectedHostIDs, [h[0].id, h[2].id, h[4].id])
        vm.click(hostID: h[0].id, modifier: .toggle)
        XCTAssertEqual(vm.selectedHostIDs, [h[2].id, h[4].id])
        vm.click(hostID: h[4].id, modifier: .toggle)
        XCTAssertEqual(vm.selectedHostIDs, [h[2].id])
        XCTAssertEqual(vm.selectedHostID, h[2].id, "one host left: its details open again")
        vm.click(hostID: h[2].id, modifier: .toggle)
        XCTAssertTrue(vm.selectedHostIDs.isEmpty)
        XCTAssertNil(vm.selectedHostID)
    }

    func testShiftClickSelectsTheRangeFromTheAnchorInVisibleOrder() async throws {
        let (vm, h) = try await makeModel()
        vm.click(hostID: h[1].id, modifier: .none)
        vm.click(hostID: h[3].id, modifier: .extend)
        XCTAssertEqual(vm.selectedHostIDs, [h[1].id, h[2].id, h[3].id])
        XCTAssertNil(vm.selectedHostID)
        // The anchor stays: a second shift-click replaces the range.
        vm.click(hostID: h[0].id, modifier: .extend)
        XCTAssertEqual(vm.selectedHostIDs, [h[0].id, h[1].id])
        // ⌘-click moves the anchor.
        vm.click(hostID: h[4].id, modifier: .toggle)
        vm.click(hostID: h[2].id, modifier: .extend)
        XCTAssertEqual(vm.selectedHostIDs, [h[2].id, h[3].id, h[4].id])
    }

    func testShiftClickWithoutAnAnchorSelectsOnlyThatHost() async throws {
        let (vm, h) = try await makeModel()
        vm.click(hostID: h[2].id, modifier: .extend)
        XCTAssertEqual(vm.selectedHostIDs, [h[2].id])
        XCTAssertEqual(vm.selectedHostID, h[2].id)
    }

    func testSettingSelectedHostIDFromOutsideSelectsJustThatHost() async throws {
        let (vm, h) = try await makeModel()
        vm.click(hostID: h[0].id, modifier: .none)
        vm.click(hostID: h[1].id, modifier: .toggle)
        vm.selectedHostID = h[4].id // "Edit host" from a terminal tab, New host
        XCTAssertEqual(vm.selectedHostIDs, [h[4].id])
        vm.selectedHostID = nil // Host Details closed
        XCTAssertTrue(vm.selectedHostIDs.isEmpty)
        XCTAssertFalse(vm.isHostSelected(h[4].id))
    }

    func testWorkspaceHostsNeedTwoSelectedIncludingTheClickedOneInVisibleOrder() async throws {
        let (vm, h) = try await makeModel()
        vm.click(hostID: h[3].id, modifier: .none)
        XCTAssertNil(vm.workspaceHostIDs(forContextMenuOn: h[3].id), "one host is not a workspace")
        vm.click(hostID: h[1].id, modifier: .toggle)
        XCTAssertEqual(vm.workspaceHostIDs(forContextMenuOn: h[3].id), [h[1].id, h[3].id])
        XCTAssertNil(vm.workspaceHostIDs(forContextMenuOn: h[0].id), "right-click outside the selection")
    }

    func testOnlyVisibleHostsCountForTheWorkspace() async throws {
        let (vm, h) = try await makeModel()
        vm.click(hostID: h[0].id, modifier: .none)
        vm.click(hostID: h[1].id, modifier: .toggle)
        vm.click(hostID: h[2].id, modifier: .toggle)
        vm.searchText = "c"
        XCTAssertNil(vm.workspaceHostIDs(forContextMenuOn: h[2].id))
        XCTAssertEqual(vm.selectedVisibleHostIDs, [h[2].id])
        vm.searchText = ""
        XCTAssertEqual(vm.selectedVisibleHostIDs, [h[0].id, h[1].id, h[2].id])
        XCTAssertTrue(vm.isHostSelected(h[1].id))
    }

    func testNewHostIsTheOnlySelectedHost() async throws {
        let (vm, h) = try await makeModel()
        vm.click(hostID: h[0].id, modifier: .none)
        vm.click(hostID: h[1].id, modifier: .toggle)
        let host = try await vm.newHost()
        XCTAssertEqual(vm.selectedHostIDs, [host.id])
        XCTAssertEqual(vm.selectedHostID, host.id)
    }
}
