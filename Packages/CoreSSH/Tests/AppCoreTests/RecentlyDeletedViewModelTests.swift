import XCTest
import CoreModels
@testable import AppCore

/// Settings → Recently Deleted (hosts): list, restore, delete permanently, empty.
@MainActor
final class RecentlyDeletedViewModelTests: XCTestCase {
    private var vault: LocalVault!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    private func host(_ label: String, group: UUID? = nil) async throws -> SavedHost {
        try await vault.save(SavedHost(label: label, address: "\(label).example", groupID: group,
                                       username: "root", password: "pw-\(label)"))
    }

    func testListsDeletedHostsNewestFirst() async throws {
        let a = try await host("a"), b = try await host("b"), kept = try await host("kept")
        try await vault.delete(SavedHost.self, id: a.id)
        try await vault.delete(SavedHost.self, id: b.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        XCTAssertEqual(model.deletedHosts.map(\.label), ["b", "a"])
        XCTAssertFalse(model.deletedHosts.contains { $0.id == kept.id })
        XCTAssertEqual(model.deletedHosts.first?.password, "pw-b", "kept whole, so it can come back")
    }

    func testRestoreBringsTheHostBackWithItsDetails() async throws {
        let g = try await vault.save(HostGroup(name: "G"))
        let a = try await host("a", group: g.id)
        try await vault.delete(SavedHost.self, id: a.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        try await model.restore(a.id)
        let back = try XCTUnwrap(vault.get(SavedHost.self, id: a.id))
        XCTAssertEqual(back.label, "a")
        XCTAssertEqual(back.password, "pw-a")
        XCTAssertEqual(back.groupID, g.id)
        XCTAssertTrue(model.deletedHosts.isEmpty)
    }

    func testRestoringIntoADeletedGroupLandsAtTheTop() async throws {
        let g = try await vault.save(HostGroup(name: "G"))
        let a = try await host("a", group: g.id)
        try await vault.delete(SavedHost.self, id: a.id)
        try await vault.deleteGroup(id: g.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        try await model.restore(a.id)
        XCTAssertNil(vault.get(SavedHost.self, id: a.id)?.groupID)
    }

    func testDeletePermanentlyWipesTheDetailsButKeepsTheDeletion() async throws {
        let a = try await host("a"), b = try await host("b")
        try await vault.delete(SavedHost.self, id: a.id)
        try await vault.delete(SavedHost.self, id: b.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        try await model.deletePermanently(a.id)
        XCTAssertEqual(model.deletedHosts.map(\.label), ["b"])
        let tombstone = try XCTUnwrap(vault.deletedRecords(SavedHost.self).first { $0.id == a.id })
        XCTAssertTrue(tombstone.deleted, "still a deletion, so another Mac can't bring it back")
        XCTAssertEqual(tombstone.label, "")
        XCTAssertNil(tombstone.password)
        XCTAssertNil(vault.get(SavedHost.self, id: a.id))

        try await model.empty()
        XCTAssertTrue(model.deletedHosts.isEmpty)
        XCTAssertNil(vault.deletedRecords(SavedHost.self).first { $0.id == b.id }?.password)
    }
}
