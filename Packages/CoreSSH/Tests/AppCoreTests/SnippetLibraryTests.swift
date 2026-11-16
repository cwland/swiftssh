import XCTest
import CoreModels
@testable import AppCore

final class SnippetLibraryTests: XCTestCase {
    func testCatalogIsWellFormed() {
        let entries = SnippetLibrary.entries
        XCTAssertGreaterThanOrEqual(entries.count, 45)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "ids are unique")
        XCTAssertEqual(Set(entries.map(\.script)).count, entries.count, "scripts are unique")
        XCTAssertEqual(Set(entries.map(\.category)), Set(SnippetLibrary.categories), "every category is used")
        for entry in entries {
            XCTAssertFalse(entry.name.isEmpty, entry.id)
            XCTAssertFalse(entry.detail.isEmpty, entry.id)
            XCTAssertFalse(entry.script.trimmingCharacters(in: .whitespaces).isEmpty, entry.id)
            XCTAssertFalse(entry.script.contains("\n"), "\(entry.id): one line")
            // Unbalanced {{ }} would show literally to the user.
            XCTAssertEqual(entry.script.components(separatedBy: "{{").count,
                           entry.script.components(separatedBy: "}}").count, entry.id)
        }
    }

    func testNothingDestructiveRunsWithoutAskingForItsTarget() {
        for entry in SnippetLibrary.entries {
            for banned in ["rm -rf", "mkfs", "dd if=", "> /dev/sd", ":(){", "--force", "prune -a"] {
                XCTAssertFalse(entry.script.contains(banned), "\(entry.id) contains \(banned)")
            }
            // No segment of the command line runs a power command.
            let segments = entry.script.components(separatedBy: CharacterSet(charactersIn: ";|&"))
            for segment in segments {
                let words = segment.split(separator: " ").map(String.init).filter { $0 != "sudo" }
                if let program = words.first {
                    XCTAssertFalse(["reboot", "shutdown", "poweroff", "halt"].contains(program), entry.id)
                }
            }
            let acts = ["restart", "stop", "kill", "userdel", "passwd"].contains { entry.script.contains("\($0) ") }
            if acts {
                XCTAssertTrue(SnippetTemplate(entry.script).hasPlaceholders, "\(entry.id) asks for its target")
            }
        }
    }

    func testPlaceholdersAreRealOnesAndDockerTemplatesStayLiteral() {
        let restart = SnippetLibrary.entries.first { $0.id == "services.restart" }
        XCTAssertEqual(SnippetTemplate(restart?.script ?? "").placeholders.map(\.name), ["service"])
        let ps = SnippetLibrary.entries.first { $0.id == "docker.ps" }
        XCTAssertNotNil(ps)
        XCTAssertFalse(SnippetTemplate(ps?.script ?? "").hasPlaceholders, "{{.Names}} is Docker's, not ours")
    }
}

@MainActor
final class SnippetLibraryViewModelTests: XCTestCase {
    private var vault: LocalVault!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
    }

    private func entry(_ id: String) -> SnippetLibrary.Entry {
        SnippetLibrary.entries.first { $0.id == id }!
    }

    func testAddsTheCheckedOnesIntoAPackagePerCategory() async {
        let model = SnippetLibraryViewModel(vault: vault)
        model.toggle(entry("system.uptime"))
        model.toggle(entry("docker.ps"))
        XCTAssertEqual(model.selectedCount, 2)
        XCTAssertEqual(model.addSelected(), 2)
        let saved = vault.all(Snippet.self)
        XCTAssertEqual(Set(saved.map(\.name)), [entry("system.uptime").name, entry("docker.ps").name])
        XCTAssertEqual(saved.first { $0.script == entry("docker.ps").script }?.package, "Docker")
        XCTAssertEqual(model.selectedCount, 0, "the selection is cleared")
        XCTAssertTrue(model.isAdded(entry("docker.ps")))
    }

    func testAlreadyAddedCannotBeCheckedOrAddedTwice() async {
        vault.saveNow(Snippet(name: "mine", script: entry("system.uptime").script))
        let model = SnippetLibraryViewModel(vault: vault)
        XCTAssertTrue(model.isAdded(entry("system.uptime")), "matched by script, whatever its name")
        model.toggle(entry("system.uptime"))
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertEqual(model.addSelected(), 0)
        XCTAssertEqual(vault.all(Snippet.self).count, 1)
    }

    func testDeletedSnippetCanBeAddedAgain() async {
        let saved = vault.saveNow(Snippet(name: "x", script: entry("system.uptime").script))
        var deleted = saved
        deleted.deleted = true
        vault.saveNow(deleted)
        XCTAssertFalse(SnippetLibraryViewModel(vault: vault).isAdded(entry("system.uptime")))
    }

    func testCategoryCheckboxSelectsEveryAddableEntry() async {
        let model = SnippetLibraryViewModel(vault: vault)
        vault.saveNow(Snippet(name: "x", script: entry("docker.ps").script))
        XCTAssertEqual(model.categoryState("Docker"), .none)
        model.setCategory("Docker", selected: true)
        let addable = SnippetLibrary.entries.filter { $0.category == "Docker" && $0.id != "docker.ps" }
        XCTAssertEqual(model.selectedCount, addable.count)
        XCTAssertEqual(model.categoryState("Docker"), .all)
        model.toggle(addable[0])
        XCTAssertEqual(model.categoryState("Docker"), .some)
        model.setCategory("Docker", selected: false)
        XCTAssertEqual(model.selectedCount, 0)
    }

    func testSearchFiltersSectionsByNameScriptOrDetail() async {
        let model = SnippetLibraryViewModel(vault: vault)
        XCTAssertEqual(model.sections.map(\.category), SnippetLibrary.categories)
        model.searchText = "journalctl"
        XCTAssertFalse(model.sections.isEmpty)
        XCTAssertTrue(model.sections.allSatisfy { section in
            section.entries.allSatisfy { ($0.name + $0.script + $0.detail).localizedCaseInsensitiveContains("journalctl") }
        })
        model.searchText = "zzz-nothing"
        XCTAssertTrue(model.sections.isEmpty)
    }

    func testCheckingWhileSearchingKeepsHiddenChoices() async {
        let model = SnippetLibraryViewModel(vault: vault)
        model.toggle(entry("system.uptime"))
        model.searchText = "docker"
        model.setCategory("Docker", selected: true)
        XCTAssertTrue(model.isSelected(entry("system.uptime")))
        model.searchText = ""
        XCTAssertGreaterThan(model.selectedCount, 1)
    }
}
