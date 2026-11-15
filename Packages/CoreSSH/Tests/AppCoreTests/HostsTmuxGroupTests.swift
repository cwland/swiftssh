import XCTest
import CoreModels
@testable import AppCore

@MainActor
final class HostsTmuxGroupTests: XCTestCase {
    private var vault: LocalVault!
    private var vm: HostsViewModel!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
        vm = HostsViewModel(vault: vault)
    }

    func testGroupChoiceReadsInheritForNilAndMissingGroups() async throws {
        let plain = try await vault.save(HostGroup(name: "P"))
        let on = try await vault.save(HostGroup(name: "O", defaultTmuxSession: .session("ops")))
        XCTAssertEqual(vm.tmuxChoice(ofGroup: plain.id), .inherit)
        XCTAssertEqual(vm.tmuxChoice(ofGroup: on.id), .session("ops"))
        XCTAssertEqual(vm.tmuxChoice(ofGroup: UUID()), .inherit)
    }

    func testInheritedSummaryComesFromTheParents() async throws {
        let root = try await vault.save(HostGroup(name: "Root", defaultTmuxSession: .session("ops")))
        let mid = try await vault.save(HostGroup(name: "Mid", parentID: root.id, defaultTmuxSession: .off))
        let leaf = try await vault.save(HostGroup(name: "Leaf", parentID: mid.id))
        XCTAssertEqual(vm.inheritedTmuxSummary(ofGroup: mid.id), "Default (group: on, ops)", "its own choice is left out")
        XCTAssertEqual(vm.inheritedTmuxSummary(ofGroup: leaf.id), "Default (group: off)")
        XCTAssertEqual(vm.inheritedTmuxSummary(ofGroup: root.id), "Default (off)")
    }

    func testSetTmuxSavesAndKeepsOtherFields() async throws {
        let group = try await vault.save(HostGroup(name: "G", defaultPort: 2222, defaultThemeID: "nord"))
        try await vm.setTmux(.session(" work "), forGroup: group.id)
        var stored = try XCTUnwrap(vault.get(HostGroup.self, id: group.id))
        XCTAssertEqual(stored.defaultTmuxSession, .session("work"), "trimmed")
        XCTAssertEqual(stored.defaultPort, 2222)
        XCTAssertEqual(stored.defaultThemeID, "nord")
        try await vm.setTmux(.off, forGroup: group.id)
        stored = try XCTUnwrap(vault.get(HostGroup.self, id: group.id))
        XCTAssertEqual(stored.defaultTmuxSession, .off)
        try await vm.setTmux(.inherit, forGroup: group.id)
        XCTAssertNil(vault.get(HostGroup.self, id: group.id)?.defaultTmuxSession, "Default is stored as nil")
    }

    func testSetTmuxIsIdempotent() async throws {
        let group = try await vault.save(HostGroup(name: "G", defaultTmuxSession: .session("main")))
        let before = try XCTUnwrap(vault.get(HostGroup.self, id: group.id)).updatedAt
        try await vm.setTmux(.session("main"), forGroup: group.id)
        XCTAssertEqual(vault.get(HostGroup.self, id: group.id)?.updatedAt, before)
    }

    func testInvalidNameThrowsAndSavesNothing() async throws {
        let group = try await vault.save(HostGroup(name: "G", defaultTmuxSession: .off))
        for bad in ["", "a b", "x'y", "$(id)", String(repeating: "a", count: 65)] {
            do {
                try await vm.setTmux(.session(bad), forGroup: group.id)
                XCTFail("expected an error for \(bad)")
            } catch let error as HostsError {
                XCTAssertEqual(error, .invalidTmuxSessionName)
                XCTAssertEqual(error.errorDescription, TmuxLabels.invalidNameMessage)
            }
            XCTAssertEqual(vault.get(HostGroup.self, id: group.id)?.defaultTmuxSession, .off)
        }
    }

    func testSetTmuxOnMissingGroupDoesNothing() async throws {
        try await vm.setTmux(.session("main"), forGroup: UUID())
        XCTAssertTrue(vault.all(HostGroup.self).isEmpty)
    }

    func testHostInGroupInheritsTheGroupSession() async throws {
        let group = try await vault.save(HostGroup(name: "G"))
        let host = try await vault.save(SavedHost(label: "h", address: "h", groupID: group.id, username: "u"))
        try await vm.setTmux(.session("ops"), forGroup: group.id)
        XCTAssertEqual(HostDetailsViewModel(vault: vault, hostID: host.id).effectiveTmuxSession, "ops")
    }
}
