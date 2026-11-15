import XCTest
import CoreModels
@testable import AppCore

/// Settings → Recently Deleted (hosts, host groups, snippets): list, restore, delete permanently, empty.
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

    // MARK: Groups

    func testListsDeletedGroupsNewestFirst() async throws {
        let a = try await vault.save(HostGroup(name: "A", defaultPort: 2222))
        let b = try await vault.save(HostGroup(name: "B"))
        _ = try await vault.save(HostGroup(name: "Kept"))
        try await vault.deleteGroup(id: a.id)
        try await vault.deleteGroup(id: b.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        XCTAssertEqual(model.deletedGroups.map(\.name), ["B", "A"])
        XCTAssertEqual(model.deletedGroups.last?.defaultPort, 2222, "kept whole, so it can come back")
        XCTAssertFalse(model.isEmpty)
    }

    func testRestoreBringsTheGroupBackUnderItsParent() async throws {
        let snippet = try await vault.save(Snippet(name: "s", script: "ls"))
        let parent = try await vault.save(HostGroup(name: "P"))
        let g = try await vault.save(HostGroup(name: "G", parentID: parent.id, defaultTmuxSession: .session("ops"),
                                               startupSnippetID: snippet.id))
        try await vault.deleteGroup(id: g.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        try await model.restore(g.id)
        let back = try XCTUnwrap(vault.get(HostGroup.self, id: g.id))
        XCTAssertEqual(back.name, "G")
        XCTAssertEqual(back.parentID, parent.id)
        XCTAssertEqual(back.defaultTmuxSession, .session("ops"))
        XCTAssertEqual(back.startupSnippetID, snippet.id)
        XCTAssertTrue(model.deletedGroups.isEmpty)
    }

    func testRestoringAGroupWhoseParentWasDeletedLandsAtTheTop() async throws {
        let parent = try await vault.save(HostGroup(name: "P"))
        let g = try await vault.save(HostGroup(name: "G", parentID: parent.id))
        try await vault.deleteGroup(id: g.id)
        try await vault.deleteGroup(id: parent.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        try await model.restore(g.id)
        XCTAssertNil(vault.get(HostGroup.self, id: g.id)?.parentID)
        XCTAssertEqual(model.deletedGroups.map(\.name), ["P"])
    }

    func testDeleteGroupPermanentlyWipesTheDetailsButKeepsTheDeletion() async throws {
        let g = try await vault.save(HostGroup(name: "G", defaultPort: 2222))
        try await vault.deleteGroup(id: g.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        try await model.deletePermanently(g.id)
        XCTAssertTrue(model.deletedGroups.isEmpty)
        let tombstone = try XCTUnwrap(vault.deletedRecords(HostGroup.self).first { $0.id == g.id })
        XCTAssertTrue(tombstone.deleted)
        XCTAssertEqual(tombstone.name, "")
        XCTAssertNil(tombstone.defaultPort)
        XCTAssertNil(vault.get(HostGroup.self, id: g.id))
        try await model.restore(g.id)
        XCTAssertNil(vault.get(HostGroup.self, id: g.id), "a wiped group can't be restored")
    }

    // MARK: Snippets

    func testListsDeletedSnippetsNewestFirstAndRestoresWithTheirGroupName() async throws {
        let snippets = SnippetsViewModel(vault: vault)
        let a = snippets.create(name: "a", script: "uptime", package: "Ops")
        let b = snippets.create(name: "b", script: "df -h", package: nil)
        snippets.delete(a.id)
        snippets.delete(b.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        XCTAssertEqual(model.deletedSnippets.map(\.name), ["b", "a"])
        XCTAssertTrue(snippets.packages.isEmpty, "no snippet left in Ops")
        try await model.restore(a.id)
        let back = try XCTUnwrap(vault.get(Snippet.self, id: a.id))
        XCTAssertEqual(back.script, "uptime")
        XCTAssertEqual(back.package, "Ops", "comes back with its snippet group's name")
        XCTAssertEqual(snippets.packages, ["Ops"])
        XCTAssertEqual(model.deletedSnippets.map(\.name), ["b"])
    }

    func testDeleteSnippetPermanentlyWipesTheScript() async throws {
        let s = try await vault.save(Snippet(name: "s", script: "secret-ish", package: "P"))
        try await vault.delete(Snippet.self, id: s.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        try await model.deletePermanently(s.id)
        XCTAssertTrue(model.deletedSnippets.isEmpty)
        let tombstone = try XCTUnwrap(vault.deletedRecords(Snippet.self).first { $0.id == s.id })
        XCTAssertTrue(tombstone.deleted)
        XCTAssertEqual(tombstone.script, "")
        XCTAssertNil(tombstone.package)
    }

    // MARK: Empty

    func testEmptyCoversHostsGroupsAndSnippets() async throws {
        let h = try await host("h")
        let g = try await vault.save(HostGroup(name: "G"))
        let s = try await vault.save(Snippet(name: "s", script: "ls"))
        try await vault.delete(SavedHost.self, id: h.id)
        try await vault.deleteGroup(id: g.id)
        try await vault.delete(Snippet.self, id: s.id)
        let model = RecentlyDeletedViewModel(vault: vault)
        XCTAssertEqual(model.count, 3)
        try await model.empty()
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.count, 0)
        XCTAssertEqual(vault.deletedRecords(HostGroup.self).first { $0.id == g.id }?.name, "")
        XCTAssertEqual(vault.deletedRecords(Snippet.self).first { $0.id == s.id }?.script, "")
    }

    func testUnknownIDsAreIgnored() async throws {
        let model = RecentlyDeletedViewModel(vault: vault)
        let live = try await vault.save(Snippet(name: "s", script: "ls"))
        try await model.deletePermanently(live.id)
        XCTAssertEqual(vault.get(Snippet.self, id: live.id)?.script, "ls", "only deleted records are touched")
        try await model.restore(UUID())
        try await model.deletePermanently(UUID())
        XCTAssertTrue(model.isEmpty)
    }
}
