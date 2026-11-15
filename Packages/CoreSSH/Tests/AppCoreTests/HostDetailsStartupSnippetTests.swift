import XCTest
import CoreModels
@testable import AppCore

@MainActor
final class HostDetailsStartupSnippetTests: XCTestCase {
    private var vault: LocalVault!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    private func stored(_ id: UUID) -> SavedHost? { vault.get(SavedHost.self, id: id) }

    func testSetAndClearSaveAtOnce() async {
        let host = vault.saveNow(SavedHost(label: "Web", address: "web", username: "root", password: "pw"))
        let snippet = vault.saveNow(Snippet(name: "s", script: "cd /srv"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertNil(vm.startupSnippetID)
        vm.startupSnippetID = snippet.id
        XCTAssertEqual(stored(host.id)?.startupSnippetID, snippet.id)
        XCTAssertEqual(vm.startupSnippetID, snippet.id)
        XCTAssertEqual(stored(host.id)?.username, "root", "nothing else changes")
        XCTAssertEqual(stored(host.id)?.password, "pw")
        vm.startupSnippetID = nil
        XCTAssertNil(stored(host.id)?.startupSnippetID)
    }

    func testSettingTheSameValueSavesNothing() async throws {
        let snippet = vault.saveNow(Snippet(name: "s", script: "ls"))
        let host = vault.saveNow(SavedHost(label: "Web", address: "web", startupSnippetID: snippet.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        let revision = vault.revision
        vm.startupSnippetID = snippet.id
        XCTAssertEqual(vault.revision, revision)
        let bare = vault.saveNow(SavedHost(label: "Bare", address: "b"))
        let other = HostDetailsViewModel(vault: vault, hostID: bare.id)
        let r2 = vault.revision
        other.startupSnippetID = nil
        XCTAssertEqual(vault.revision, r2)
    }

    func testMissingOrDeletedSnippetReadsAsNoneAndCanBeCleared() async throws {
        let snippet = vault.saveNow(Snippet(name: "s", script: "ls"))
        let host = vault.saveNow(SavedHost(label: "Web", address: "web", startupSnippetID: snippet.id))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        try await vault.delete(Snippet.self, id: snippet.id)
        XCTAssertNil(vm.startupSnippetID)
        XCTAssertEqual(stored(host.id)?.startupSnippetID, snippet.id, "reading changes nothing")
        vm.startupSnippetID = nil
        XCTAssertNil(stored(host.id)?.startupSnippetID, "None clears the stale id")
    }

    func testDeletedHostIgnoresSets() async throws {
        let host = vault.saveNow(SavedHost(label: "Web", address: "web"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        try await vault.delete(SavedHost.self, id: host.id)
        vm.startupSnippetID = UUID()
        XCTAssertNil(stored(host.id))
        XCTAssertNil(vm.startupSnippetID)
    }

    func testCandidatesPassThroughAndHiddenCount() async {
        vault.saveNow(Snippet(name: "b", script: "ls"))
        vault.saveNow(Snippet(name: "a", script: "uptime"))
        vault.saveNow(Snippet(name: "ask", script: "cd {{dir}}"))
        let host = vault.saveNow(SavedHost(label: "Web", address: "web"))
        let vm = HostDetailsViewModel(vault: vault, hostID: host.id)
        XCTAssertEqual(vm.startupCandidates().map(\.name), ["a", "b"])
        XCTAssertEqual(vm.hiddenStartupSnippetCount, 1)
    }
}
