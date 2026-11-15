import XCTest
import CoreModels
@testable import AppCore

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
}
