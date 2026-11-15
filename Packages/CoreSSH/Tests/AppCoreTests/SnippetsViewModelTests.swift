import XCTest
import CoreModels
import SyncCore
@testable import AppCore

@MainActor
final class SnippetsViewModelTests: XCTestCase {
    private var p: InMemoryVaultPersistence!
    private var vault: LocalVault!
    private var vm: SnippetsViewModel!

    override func setUp() async throws {
        p = InMemoryVaultPersistence()
        vault = try await LocalVault.open(persistence: p, newDeviceID: { "dev-1" })
        vm = SnippetsViewModel(vault: vault)
    }

    private func stored(_ id: UUID) -> Snippet? { vault.get(Snippet.self, id: id) }

    private func names(_ section: SnippetsViewModel.Section) -> [String] { section.snippets.map(\.name) }

    // MARK: Sections

    func testEmpty() async {
        XCTAssertEqual(vm.sections.count, 0)
        XCTAssertEqual(vm.packages, [])
    }

    func testSectionsUnpackagedFirstThenPackagesAZWithSnippetsAZ() async {
        vm.create(name: "zeta", script: "z", package: "ops")
        vm.create(name: "Beta", script: "b", package: nil)
        vm.create(name: "alpha", script: "a", package: nil)
        vm.create(name: "gamma", script: "g", package: "Docker")
        vm.create(name: "delta", script: "d", package: "ops")
        let sections = vm.sections
        XCTAssertEqual(sections.map(\.package), [nil, "Docker", "ops"])
        XCTAssertEqual(sections.map(\.id), ["", "Docker", "ops"])
        XCTAssertEqual(names(sections[0]), ["alpha", "Beta"])
        XCTAssertEqual(names(sections[1]), ["gamma"])
        XCTAssertEqual(names(sections[2]), ["delta", "zeta"])
        XCTAssertEqual(vm.packages, ["Docker", "ops"])
    }

    func testNoUnpackagedSectionWhenEverySnippetIsInAPackage() async {
        vm.create(name: "a", script: "a", package: "ops")
        XCTAssertEqual(vm.sections.map(\.package), ["ops"])
    }

    func testDeletedSnippetsAreHidden() async {
        let s = vm.create(name: "a", script: "a", package: "ops")
        vm.delete(s.id)
        XCTAssertEqual(vm.sections.count, 0)
        XCTAssertEqual(vm.packages, [])
    }

    func testPackagesAreDistinctAndSorted() async {
        vm.create(name: "1", script: "", package: "b")
        vm.create(name: "2", script: "", package: "a")
        vm.create(name: "3", script: "", package: "b")
        vm.create(name: "4", script: "", package: "C")
        XCTAssertEqual(vm.packages, ["a", "b", "C"])
    }

    // MARK: Search

    func testSearchMatchesNameOrScriptCaseInsensitive() async {
        vm.create(name: "Update packages", script: "apt update", package: nil)
        vm.create(name: "Disk", script: "df -h", package: "ops")
        vm.create(name: "Logs", script: "journalctl -u Docker", package: "ops")
        vm.searchText = "  DOCKER "
        XCTAssertEqual(vm.sections.map(\.package), ["ops"])
        XCTAssertEqual(names(vm.sections[0]), ["Logs"])
        vm.searchText = "update"
        XCTAssertEqual(vm.sections.map(\.package), [nil])
        vm.searchText = "nothing"
        XCTAssertEqual(vm.sections.count, 0)
        vm.searchText = ""
        XCTAssertEqual(vm.sections.count, 2)
    }

    func testPackagesListIsNotFilteredBySearch() async {
        vm.create(name: "a", script: "", package: "ops")
        vm.searchText = "zzz"
        XCTAssertEqual(vm.packages, ["ops"])
    }

    // MARK: Create / update

    func testCreateSavesTrimmedAndSyncs() async throws {
        let s = vm.create(name: "  Disk  ", script: "df -h\n", package: "  ops ")
        XCTAssertEqual(stored(s.id)?.name, "Disk")
        XCTAssertEqual(stored(s.id)?.script, "df -h\n", "the script is kept as typed")
        XCTAssertEqual(stored(s.id)?.package, "ops")
        XCTAssertEqual(s, stored(s.id))
        await vault.flush()
        let contents = await p.contents
        XCTAssertNotNil(contents?.records.first { $0.id == s.id })
    }

    func testBlankPackageIsNone() async {
        let s = vm.create(name: "a", script: "", package: "   ")
        XCTAssertNil(stored(s.id)?.package)
    }

    func testUpdateChangesOnlyGivenFields() async {
        let s = vm.create(name: "a", script: "ls", package: "ops")
        vm.update(s.id, name: "  b ", script: nil, package: nil)
        XCTAssertEqual(stored(s.id)?.name, "b")
        XCTAssertEqual(stored(s.id)?.script, "ls")
        XCTAssertEqual(stored(s.id)?.package, "ops")
        vm.update(s.id, name: nil, script: "ls -la", package: .some(nil))
        XCTAssertEqual(stored(s.id)?.name, "b")
        XCTAssertEqual(stored(s.id)?.script, "ls -la")
        XCTAssertNil(stored(s.id)?.package)
        vm.update(s.id, name: nil, script: nil, package: .some(" new "))
        XCTAssertEqual(stored(s.id)?.package, "new")
    }

    func testUpdateIsIdempotent() async throws {
        let s = vm.create(name: "a", script: "ls", package: "ops")
        let before = try XCTUnwrap(stored(s.id)).updatedAt
        let revision = vault.revision
        vm.update(s.id, name: " a ", script: "ls", package: .some("ops"))
        vm.update(s.id, name: nil, script: nil, package: nil)
        XCTAssertEqual(stored(s.id)?.updatedAt, before)
        XCTAssertEqual(vault.revision, revision, "nothing saved")
    }

    func testUpdateOfMissingOrDeletedDoesNothing() async {
        vm.update(UUID(), name: "x", script: "y", package: nil)
        let s = vm.create(name: "a", script: "ls", package: nil)
        vm.delete(s.id)
        vm.update(s.id, name: "x", script: nil, package: nil)
        XCTAssertNil(stored(s.id))
        XCTAssertEqual(vm.sections.count, 0)
    }

    // MARK: Move

    func testMoveSeveralIntoAPackageAndOut() async throws {
        let a = vm.create(name: "a", script: "", package: nil)
        let b = vm.create(name: "b", script: "", package: "old")
        let c = vm.create(name: "c", script: "", package: nil)
        vm.move([a.id, b.id], toPackage: " ops ")
        XCTAssertEqual(stored(a.id)?.package, "ops")
        XCTAssertEqual(stored(b.id)?.package, "ops")
        XCTAssertNil(stored(c.id)?.package)
        XCTAssertEqual(vm.packages, ["ops"])
        let stamp = try XCTUnwrap(stored(a.id)).updatedAt
        vm.move([a.id], toPackage: "ops")
        XCTAssertEqual(stored(a.id)?.updatedAt, stamp, "moving to its own package saves nothing")
        vm.move([a.id, UUID()], toPackage: nil)
        XCTAssertNil(stored(a.id)?.package)
        vm.move([b.id], toPackage: "  ")
        XCTAssertNil(stored(b.id)?.package, "blank = no package")
    }

    // MARK: Packages without snippets yet

    func testAddedPackageShowsEmptyUntilUsed() async {
        XCTAssertEqual(vm.addPackage("  Docker "), "Docker")
        XCTAssertNil(vm.addPackage("   "))
        XCTAssertEqual(vm.packages, ["Docker"])
        XCTAssertEqual(vm.sections.map(\.package), ["Docker"])
        XCTAssertEqual(vm.sections[0].snippets, [])
        vm.searchText = "x"
        XCTAssertEqual(vm.sections.count, 0, "empty packages are hidden while searching")
        vm.searchText = ""
        let s = vm.create(name: "ps", script: "docker ps", package: nil)
        vm.move([s.id], toPackage: "Docker")
        XCTAssertEqual(vm.packages, ["Docker"])
        XCTAssertEqual(names(vm.sections[0]), ["ps"])
    }

    // MARK: Duplicate / delete

    func testDuplicateCopiesEverythingButIDAndName() async throws {
        let host = UUID()
        let s = vm.create(name: "Disk", script: "df -h", package: "ops")
        vm.saveTargets(s.id, hostIDs: [host])
        let copy = try XCTUnwrap(vm.duplicate(s.id))
        XCTAssertNotEqual(copy.id, s.id)
        XCTAssertEqual(stored(copy.id)?.name, "Disk copy")
        XCTAssertEqual(stored(copy.id)?.script, "df -h")
        XCTAssertEqual(stored(copy.id)?.package, "ops")
        XCTAssertEqual(stored(copy.id)?.targetHostIDs, [host])
        XCTAssertEqual(stored(s.id)?.name, "Disk", "the original is untouched")
        XCTAssertNil(vm.duplicate(UUID()))
    }

    func testDeleteIsATombstoneThatSyncsAndIsIdempotent() async throws {
        let s = vm.create(name: "a", script: "", package: nil)
        vm.delete(s.id)
        XCTAssertNil(stored(s.id))
        let revision = vault.revision
        vm.delete(s.id)
        vm.delete(UUID())
        XCTAssertEqual(vault.revision, revision)
        await vault.flush()
        let contents = await p.contents
        let record = try XCTUnwrap(contents?.records.first { $0.id == s.id })
        XCTAssertTrue(record.deleted)
    }

    // MARK: Targets

    func testSaveTargetsDeduplicatesAndClears() async throws {
        let s = vm.create(name: "a", script: "", package: nil)
        let h1 = UUID(), h2 = UUID()
        vm.saveTargets(s.id, hostIDs: [h2, h1, h2])
        XCTAssertEqual(stored(s.id)?.targetHostIDs, [h2, h1])
        XCTAssertEqual(vm.snippet(s.id)?.targetHostIDs, [h2, h1])
        let stamp = try XCTUnwrap(stored(s.id)).updatedAt
        vm.saveTargets(s.id, hostIDs: [h2, h1])
        XCTAssertEqual(stored(s.id)?.updatedAt, stamp, "same targets save nothing")
        vm.saveTargets(s.id, hostIDs: [])
        XCTAssertNil(stored(s.id)?.targetHostIDs, "empty = none")
        vm.saveTargets(s.id, hostIDs: [h1])
        vm.saveTargets(s.id, hostIDs: nil)
        XCTAssertNil(stored(s.id)?.targetHostIDs)
    }

    // MARK: Startup candidates

    func testStartupCandidatesExcludePlaceholdersSortedAZ() async {
        vm.create(name: "zz", script: "uptime", package: "ops")
        vm.create(name: "Ask", script: "cd {{dir}}", package: nil)
        vm.create(name: "aa", script: "ls", package: nil)
        vm.create(name: "literal", script: "awk '{print $1}' {{bad name}}", package: nil)
        let gone = vm.create(name: "gone", script: "ls", package: nil)
        vm.delete(gone.id)
        XCTAssertEqual(vm.startupCandidates().map(\.name), ["aa", "literal", "zz"])
    }

    func testSnippetLookup() async {
        let s = vm.create(name: "a", script: "", package: nil)
        XCTAssertEqual(vm.snippet(s.id)?.name, "a")
        XCTAssertNil(vm.snippet(UUID()))
    }
}
