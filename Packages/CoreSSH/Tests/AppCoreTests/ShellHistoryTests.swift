import XCTest
@testable import AppCore

final class ShellHistoryTests: XCTestCase {
    private func section(_ shell: String, _ lines: String) -> String {
        "\n\(ShellHistory.marker) \(shell)\n\(lines)"
    }

    func testBashIsNewestFirstAndSkipsTimestampLines() {
        let output = section("bash", "ls\n#1700000000\ncd /var\n\nuptime\n")
        XCTAssertEqual(ShellHistory.parse(output), ["uptime", "cd /var", "ls"])
    }

    func testZshStripsExtendedHistoryPrefixAndJoinsContinuations() {
        let output = section("zsh", ": 1700000000:0;git status\n: 1700000001:3;for f in *; do\\\necho $f\\\ndone\nplain\n")
        XCTAssertEqual(ShellHistory.parse(output), ["plain", "for f in *; do\necho $f\ndone", "git status"])
    }

    func testFishReadsCmdLinesAndUnescapes() {
        let output = section("fish", "- cmd: ls -la\n  when: 1700000000\n- cmd: echo a\\nb \\\\ c\n  when: 1700000001\n  paths:\n    - /tmp\n")
        XCTAssertEqual(ShellHistory.parse(output), ["echo a\nb \\ c", "ls -la"])
    }

    func testDuplicatesKeepTheNewestPosition() {
        let output = section("bash", "ls\nuptime\nls\n  ls  \n")
        XCTAssertEqual(ShellHistory.parse(output), ["ls", "uptime"])
    }

    func testLoginShellComesFirstThenTheOthers() {
        let output = "\(ShellHistory.loginShellMarker) /usr/bin/zsh" + section("bash", "from-bash\n") + section("zsh", "from-zsh\n")
        XCTAssertEqual(ShellHistory.parse(output), ["from-zsh", "from-bash"])
    }

    func testNothingReadableIsEmpty() {
        XCTAssertEqual(ShellHistory.parse(""), [])
        XCTAssertEqual(ShellHistory.parse("\(ShellHistory.loginShellMarker) /bin/sh\n"), [])
    }

    func testLimitKeepsTheNewest() {
        let lines = (1...10).map { "cmd\($0)" }.joined(separator: "\n")
        XCTAssertEqual(ShellHistory.parse(section("bash", lines), limit: 3), ["cmd10", "cmd9", "cmd8"])
    }

    func testCommandReadsEveryShellsFileWithoutChangingAnything() {
        let command = ShellHistory.command
        XCTAssertTrue(command.contains(".bash_history"))
        XCTAssertTrue(command.contains(".zsh_history"))
        XCTAssertTrue(command.contains("fish_history"))
        XCTAssertTrue(command.contains("tail -n"))
        for writer in [">", "rm ", "history -c"] where writer != ">" {
            XCTAssertFalse(command.contains(writer))
        }
        XCTAssertFalse(command.contains("> \""), "never writes to a history file")
    }
}

@MainActor
final class ShellHistoryViewModelTests: XCTestCase {
    private struct Failure: Error, LocalizedError {
        var errorDescription: String? { "The session is not connected." }
    }

    func testLoadsAndSearches() async {
        let model = ShellHistoryViewModel(load: {
            "\(ShellHistory.marker) bash\nls\ngit status\ngit push\n"
        })
        XCTAssertEqual(model.state, .loading)
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
        let model = ShellHistoryViewModel(load: { "" })
        await model.reload()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.commands.isEmpty)
    }
}
