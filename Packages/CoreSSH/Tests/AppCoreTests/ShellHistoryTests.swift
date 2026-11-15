import XCTest
@testable import AppCore

final class ShellHistoryTests: XCTestCase {
    private func section(_ shell: String, _ lines: String) -> String {
        "\(ShellHistory.loginShellMarker) /bin/bash\n\(ShellHistory.marker) \(shell)\n\(lines)"
    }

    func testBashIsNewestFirstAndSkipsTimestampLines() throws {
        let output = section("bash", "ls\n#1700000000\ncd /var\n\nuptime\n")
        XCTAssertEqual(try ShellHistory.parse(output), ["uptime", "cd /var", "ls"])
    }

    func testZshStripsExtendedHistoryPrefixAndJoinsContinuations() throws {
        let output = section("zsh", ": 1700000000:0;git status\n: 1700000001:3;for f in *; do\\\necho $f\\\ndone\nplain\n")
        XCTAssertEqual(try ShellHistory.parse(output), ["plain", "for f in *; do\necho $f\ndone", "git status"])
    }

    func testFishReadsCmdLinesAndUnescapes() throws {
        let output = section("fish", "- cmd: ls -la\n  when: 1700000000\n- cmd: echo a\\nb \\\\ c\n  when: 1700000001\n  paths:\n    - /tmp\n")
        XCTAssertEqual(try ShellHistory.parse(output), ["echo a\nb \\ c", "ls -la"])
    }

    func testDuplicatesKeepTheNewestPosition() throws {
        let output = section("bash", "ls\nuptime\nls\n  ls  \n")
        XCTAssertEqual(try ShellHistory.parse(output), ["ls", "uptime"])
    }

    func testLoginShellComesFirstThenTheOthers() throws {
        let output = "\(ShellHistory.loginShellMarker) /usr/bin/zsh\n\(ShellHistory.marker) bash\nfrom-bash\n\(ShellHistory.marker) zsh\nfrom-zsh\n"
        XCTAssertEqual(try ShellHistory.parse(output), ["from-zsh", "from-bash"])
    }

    func testNothingReadableIsEmpty() throws {
        XCTAssertEqual(try ShellHistory.parse("\(ShellHistory.loginShellMarker) /bin/sh\n"), [])
    }

    func testLimitKeepsTheNewest() throws {
        let lines = (1...10).map { "cmd\($0)" }.joined(separator: "\n")
        XCTAssertEqual(try ShellHistory.parse(section("bash", lines), limit: 3), ["cmd10", "cmd9", "cmd8"])
    }

    func testCommandRunsUnderShWhateverTheLoginShell() {
        let command = ShellHistory.command
        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"), "fish and tcsh can't parse sh syntax")
        XCTAssertTrue(command.hasSuffix("'"))
        let script = command.dropFirst("exec /bin/sh -c '".count).dropLast()
        XCTAssertFalse(script.contains("'"), "the script needs no quoting inside the single quotes")
        for file in [".bash_history", ".zsh_history", ".zhistory", ".histfile", "fish_history", "HISTFILE"] {
            XCTAssertTrue(script.contains(file), file)
        }
        XCTAssertFalse(script.contains(">"), "never writes anything")
    }

    func testOutputWithoutTheMarkerIsAFailureNotAnEmptyHistory() {
        XCTAssertThrowsError(try ShellHistory.parse("")) { error in
            XCTAssertEqual(error.localizedDescription, "The server didn\u{2019}t run the history command.")
        }
        XCTAssertThrowsError(try ShellHistory.parse("Unknown command: exec\nmore")) { error in
            XCTAssertEqual(error.localizedDescription, "The server didn\u{2019}t run the history command: Unknown command: exec")
        }
    }

    func testOtherFilesAreReadAsZshOrBashByTheirLines() throws {
        let output = "\(ShellHistory.loginShellMarker) /bin/zsh\n\(ShellHistory.marker) other\n: 1700000000:0;ls -la\n"
        XCTAssertEqual(try ShellHistory.parse(output), ["ls -la"])
        let plain = "\(ShellHistory.loginShellMarker) /bin/zsh\n\(ShellHistory.marker) other\nuptime\n"
        XCTAssertEqual(try ShellHistory.parse(plain), ["uptime"])
    }
}

@MainActor
final class ShellHistoryViewModelTests: XCTestCase {
    private struct Failure: Error, LocalizedError {
        var errorDescription: String? { "The session is not connected." }
    }

    func testLoadsAndSearches() async {
        let model = ShellHistoryViewModel(load: {
            "\(ShellHistory.loginShellMarker) /bin/bash\n\(ShellHistory.marker) bash\nls\ngit status\ngit push\n"
        })
        XCTAssertEqual(model.state, .idle)
        await model.reload()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.commands, ["git push", "git status", "ls"])
        model.searchText = "GIT "
        XCTAssertEqual(model.commands, ["git push", "git status"], "case-insensitive, trimmed")
        model.searchText = "push st"
        XCTAssertEqual(model.commands, [], "all words must match")
        model.searchText = "push git"
        XCTAssertEqual(model.commands, ["git push"])
    }

    func testFailureShowsTheReason() async {
        let model = ShellHistoryViewModel(load: { throw Failure() })
        await model.reload()
        XCTAssertEqual(model.state, .failed("The session is not connected."))
        XCTAssertEqual(model.commands, [])
    }

    func testEmptyHistoryIsLoadedWithNothing() async {
        let model = ShellHistoryViewModel(load: { "\(ShellHistory.loginShellMarker) /bin/bash\n" })
        await model.reload()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.commands.isEmpty)
    }
}
