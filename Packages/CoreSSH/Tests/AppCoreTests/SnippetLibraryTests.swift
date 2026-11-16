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

    /// The text outside single quotes: what the login shell itself parses (a `sh -c '…'` body is quoted).
    private func unquoted(_ script: String) -> String {
        var result = ""
        var inSingleQuotes = false
        for character in script {
            if character == "'" {
                inSingleQuotes.toggle()
            } else if !inSingleQuotes {
                result.append(character)
            }
        }
        return result
    }

    /// Syntax bash and zsh run but fish 3.x does not: if/then/fi, `[ … ]` tests, `$(…)` (not inside
    /// double quotes in fish), `${VAR}` and backticks.
    private func posixOnlyConstructs(in script: String) -> [String] {
        let text = unquoted(script)
        let words = text.split(whereSeparator: { " ;&|()".contains($0) }).map(String.init)
        var found: [String] = []
        for keyword in ["if", "then", "elif", "else", "fi", "[", "[[", "case", "esac", "do", "done"] where words.contains(keyword) {
            found.append(keyword)
        }
        for construct in ["$(", "${", "`"] where text.contains(construct) {
            found.append(construct)
        }
        return found
    }

    func testEveryEntryRunsInFishToo() {
        // Run as typed by any login shell: bash, zsh, sh and fish 3.x.
        for entry in SnippetLibrary.entries {
            XCTAssertEqual(posixOnlyConstructs(in: entry.script), [], "\(entry.id): POSIX-only syntax outside sh -c '…'")
            if entry.script.contains("sh -c '") {
                XCTAssertTrue(entry.script.hasPrefix("sh -c '") || entry.script.hasPrefix("sudo sh -c '"),
                              "\(entry.id): the whole command is wrapped")
            }
        }
    }

    func testTheCheckCatchesPOSIXOnlySyntax() {
        XCTAssertEqual(posixOnlyConstructs(in: "if command -v ufw >/dev/null; then ufw status; fi"), ["if", "then", "fi"])
        XCTAssertEqual(posixOnlyConstructs(in: "[ -f /x ] && cat /x || echo no"), ["["])
        XCTAssertEqual(posixOnlyConstructs(in: "tar -czf \"$(date +%F).tgz\" ${HOME}"), ["$(", "${"])
        XCTAssertEqual(posixOnlyConstructs(in: "sh -c 'if [ -f /x ]; then cat \"$(echo /x)\"; fi'"), [])
        XCTAssertEqual(posixOnlyConstructs(in: "dpkg-query -W -f='${Status}\\n' x 2>/dev/null || rpm -q x"), [])
    }

    func testFilesArchivePassesTheFolderToShAsAnArgument() {
        let archive = SnippetLibrary.entries.first { $0.id == "files.archive" }
        let filled = SnippetTemplate(archive?.script ?? "").filled(with: ["folder": "/srv/app"])
        XCTAssertTrue(filled.hasPrefix("sh -c '"), filled)
        XCTAssertTrue(filled.hasSuffix("' sh /srv/app"), filled)
    }

    /// Parses every entry (placeholders filled with their defaults or "x") with `sh -n`, `bash -n` and,
    /// when installed, `fish --no-execute`.
    func testEveryEntryParsesInShBashAndFish() throws {
        let shells: [(name: String, flags: [String])] = [("sh", ["-n", "-c"]), ("bash", ["-n", "-c"]),
                                                         ("fish", ["--no-execute", "-c"])]
        var ran = 0
        for shell in shells {
            guard let path = Self.executable(shell.name) else { continue }
            ran += 1
            for entry in SnippetLibrary.entries {
                let template = SnippetTemplate(entry.script)
                let values = Dictionary(template.placeholders.map { ($0.name, $0.defaultValue ?? "x") },
                                        uniquingKeysWith: { a, _ in a })
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = shell.flags + [template.filled(with: values)]
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(process.terminationStatus, 0, "\(shell.name): \(entry.id): \(message)")
            }
        }
        XCTAssertGreaterThanOrEqual(ran, 2, "sh and bash are always there")
    }

    private static func executable(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
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
