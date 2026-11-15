import XCTest
import CoreModels
@testable import AppCore

/// Foundation also exports a `Host`.
private typealias Host = CoreModels.Host

/// The Group panel's "Startup snippet" (through `HostsViewModel`).
@MainActor
final class HostsStartupSnippetGroupTests: XCTestCase {
    private var vault: LocalVault!
    private var vm: HostsViewModel!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
        vm = HostsViewModel(vault: vault)
    }

    func testSetAndClearKeepOtherFields() async throws {
        let snippet = try await vault.save(Snippet(name: "s", script: "cd /srv"))
        let group = try await vault.save(HostGroup(name: "G", defaultPort: 2222, defaultTmuxSession: .off))
        XCTAssertNil(vm.startupSnippetID(ofGroup: group.id))
        try await vm.setStartupSnippet(snippet.id, forGroup: group.id)
        var stored = try XCTUnwrap(vault.get(HostGroup.self, id: group.id))
        XCTAssertEqual(stored.startupSnippetID, snippet.id)
        XCTAssertEqual(stored.defaultPort, 2222)
        XCTAssertEqual(stored.defaultTmuxSession, .off)
        XCTAssertEqual(vm.startupSnippetID(ofGroup: group.id), snippet.id)
        let revision = vault.revision
        try await vm.setStartupSnippet(snippet.id, forGroup: group.id)
        XCTAssertEqual(vault.revision, revision, "the same value saves nothing")
        try await vm.setStartupSnippet(nil, forGroup: group.id)
        stored = try XCTUnwrap(vault.get(HostGroup.self, id: group.id))
        XCTAssertNil(stored.startupSnippetID)
    }

    func testDeletedSnippetReadsAsDefaultAndMissingGroupIsIgnored() async throws {
        let snippet = try await vault.save(Snippet(name: "s", script: "ls"))
        let group = try await vault.save(HostGroup(name: "G", startupSnippetID: snippet.id))
        try await vault.delete(Snippet.self, id: snippet.id)
        XCTAssertNil(vm.startupSnippetID(ofGroup: group.id))
        try await vm.setStartupSnippet(snippet.id, forGroup: UUID())
        XCTAssertNil(vm.startupSnippetID(ofGroup: UUID()))
    }

    func testInheritedSummaryComesFromTheParents() async throws {
        let snippet = try await vault.save(Snippet(name: "Update", script: "apt update"))
        let root = try await vault.save(HostGroup(name: "Root", startupSnippetID: snippet.id))
        let leaf = try await vault.save(HostGroup(name: "Leaf", parentID: root.id))
        XCTAssertEqual(vm.inheritedStartupSnippetSummary(ofGroup: leaf.id),
                       "Default (from group \u{201C}Root\u{201D}: Update)")
        XCTAssertEqual(vm.inheritedStartupSnippetSummary(ofGroup: root.id), "Default (none)",
                       "its own choice is left out")
    }

    func testCandidatesLeaveOutPlaceholders() async throws {
        try await vault.save(Snippet(name: "b", script: "ls"))
        try await vault.save(Snippet(name: "ask", script: "cd {{dir}}"))
        XCTAssertEqual(vm.startupCandidates().map(\.name), ["b"])
        XCTAssertEqual(vm.hiddenStartupSnippetCount, 1)
    }

    // MARK: How many hosts run the group's snippet

    /// Hosts in the group or its subgroups that use Default and for which this group decides:
    /// no own snippet, not None, and no closer group with a snippet of its own.
    func testCountsTheHostsThatUseDefaultAndReachTheGroup() async throws {
        let update = try await vault.save(Snippet(name: "Update", script: "apt update"))
        let other = try await vault.save(Snippet(name: "Other", script: "ls"))
        let root = try await vault.save(HostGroup(name: "Root", startupSnippetID: update.id))
        let child = try await vault.save(HostGroup(name: "Child", parentID: root.id))
        let overriding = try await vault.save(HostGroup(name: "Own", parentID: root.id, startupSnippetID: other.id))
        try await vault.save(Host(label: "a", address: "a", groupID: root.id))
        try await vault.save(Host(label: "b", address: "b", groupID: child.id))
        var off = Host(label: "off", address: "c", groupID: root.id)
        off.startupSnippetOff = true
        try await vault.save(off)
        var own = Host(label: "own", address: "d", groupID: child.id)
        own.startupSnippetID = other.id
        try await vault.save(own)
        var ownGone = Host(label: "own deleted snippet", address: "e", groupID: child.id)
        ownGone.startupSnippetID = UUID()
        try await vault.save(ownGone)
        try await vault.save(Host(label: "under Own", address: "f", groupID: overriding.id))
        try await vault.save(Host(label: "ungrouped", address: "g"))
        var deleted = Host(label: "deleted", address: "h", groupID: root.id)
        deleted.deleted = true
        try await vault.save(deleted)

        XCTAssertEqual(vm.hostsUsingDefaultStartupSnippet(ofGroup: root.id), 3, "a, b and the one whose snippet is gone")
        XCTAssertEqual(vm.hostsUsingDefaultStartupSnippet(ofGroup: child.id), 2, "the group would decide for them")
        XCTAssertEqual(vm.hostsUsingDefaultStartupSnippet(ofGroup: overriding.id), 1)
        XCTAssertEqual(vm.hostsUsingDefaultStartupSnippet(ofGroup: UUID()), 0)

        XCTAssertEqual(vm.startupSnippetReachSummary(ofGroup: root.id), "3 hosts use Default and will run it.")
        try await vm.setStartupSnippet(nil, forGroup: root.id)
        XCTAssertEqual(vm.startupSnippetReachSummary(ofGroup: root.id),
                       "3 hosts use Default and would run a snippet chosen here.")
        XCTAssertEqual(vm.startupSnippetReachSummary(ofGroup: overriding.id), "1 host uses Default and will run it.")
        let empty = try await vault.save(HostGroup(name: "Empty", startupSnippetID: update.id))
        XCTAssertEqual(vm.startupSnippetReachSummary(ofGroup: empty.id), "No hosts use Default here, so none run it.")
    }

    func testCountIsCycleSafe() async throws {
        let snippet = try await vault.save(Snippet(name: "s", script: "ls"))
        var a = HostGroup(name: "A", startupSnippetID: snippet.id)
        let b = HostGroup(name: "B", parentID: a.id)
        a.parentID = b.id
        try await vault.save(a)
        try await vault.save(b)
        try await vault.save(Host(label: "h", address: "h", groupID: b.id))
        XCTAssertEqual(vm.hostsUsingDefaultStartupSnippet(ofGroup: a.id), 1)
        XCTAssertEqual(vm.hostsUsingDefaultStartupSnippet(ofGroup: UUID()), 0)
    }
}
