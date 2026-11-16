import Foundation
import Observation

/// The server's own shell history, read over an exec channel of the tab's connection (bash, zsh and
/// fish files). Only read, never written; kept in memory by the History panel and never stored or
/// synced. Reading the server's file (rather than recording what is typed) means text typed at a
/// password prompt can never end up in it.
public enum ShellHistory {
    /// Starts each history file's section in `command`'s output, followed by the shell's name.
    static let marker = "@@TR-HISTORY"
    /// Followed by the login shell (`$SHELL`), whose history is listed first.
    static let loginShellMarker = "@@TR-SHELL"
    /// Lines read from the end of each file (keeps the output well under the exec channel's 1 MB cap).
    static let linesPerFile = 3000

    /// The server ran something else than `command` (a shell that refused it, a restricted account).
    public struct CommandFailed: LocalizedError, Equatable {
        /// The first line the server printed instead, if any.
        public let output: String?
        public var errorDescription: String? {
            "The server didn\u{2019}t run the history command" + (output.map { ": \($0)" } ?? ".")
        }
    }

    /// Prints the login shell, then the last lines of every readable history file, each after a marker.
    /// Runs under /bin/sh whatever the login shell is (the exec channel uses the login shell, and fish
    /// or tcsh can't parse sh syntax; `exec /bin/sh -c '…'` parses in all of them). Read-only.
    public static let command: String = {
        let files = [
            ("bash", "$HOME/.bash_history"),
            ("zsh", "${ZDOTDIR:-$HOME}/.zsh_history"),
            ("zsh", "$HOME/.zhistory"),
            ("zsh", "$HOME/.histfile"),
            ("fish", "${XDG_DATA_HOME:-$HOME/.local/share}/fish/fish_history"),
            ("other", "$HISTFILE"),
        ]
        var parts = ["printf \"%s %s\\n\" \(loginShellMarker) \"$SHELL\""]
        for (shell, path) in files {
            parts.append("if [ -n \"\(path)\" ] && [ -f \"\(path)\" ] && [ -r \"\(path)\" ]; then printf \"\\n%s %s\\n\" \(marker) \(shell); tail -n \(linesPerFile) \"\(path)\"; fi")
        }
        parts.append("true")
        return "exec /bin/sh -c '" + parts.joined(separator: "; ") + "'"
    }()

    /// The commands in `output` of `command`: the login shell's newest first, then the other shells'
    /// (each newest first); trimmed, empty ones dropped, each command once (at its newest position).
    /// Throws `CommandFailed` when the output isn't the command's.
    public static func parse(_ output: String, limit: Int = 5000) throws -> [String] {
        var loginShell: String?
        var sections: [(shell: String, lines: [Substring])] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(loginShellMarker + " ") {
                let path = line.dropFirst(loginShellMarker.count + 1)
                loginShell = path.split(separator: "/").last.map(String.init) ?? ""
            } else if line.hasPrefix(marker + " ") {
                sections.append((String(line.dropFirst(marker.count + 1)), []))
            } else if !sections.isEmpty {
                sections[sections.count - 1].lines.append(line)
            }
        }
        guard let loginShell else {
            let first = output.split(whereSeparator: \.isNewline).first
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
            throw CommandFailed(output: first)
        }
        // The login shell's files first (stable otherwise).
        sections = sections.filter { $0.shell == loginShell } + sections.filter { $0.shell != loginShell }
        var seen = Set<String>()
        var result: [String] = []
        for section in sections {
            let commands: [String]
            switch section.shell {
            case "zsh": commands = zsh(section.lines)
            case "fish": commands = fish(section.lines)
            case "bash": commands = bash(section.lines)
            default:
                // $HISTFILE: zsh's extended format or plain lines.
                let isZsh = section.lines.contains { $0.hasPrefix(": ") && $0.contains(";") }
                commands = isZsh ? zsh(section.lines) : bash(section.lines)
            }
            for command in commands.reversed() {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                result.append(trimmed)
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// One command per line; `#<digits>` lines are HISTTIMEFORMAT timestamps.
    private static func bash(_ lines: [Substring]) -> [String] {
        lines.compactMap { line in
            if line.hasPrefix("#"), line.dropFirst().allSatisfy(\.isNumber), line.count > 1 { return nil }
            return String(line)
        }
    }

    /// `: <start>:<elapsed>;command` (extended history) or plain lines; a line ending in `\` continues
    /// the command on the next line.
    private static func zsh(_ lines: [Substring]) -> [String] {
        var commands: [String] = []
        var pending: String?
        for raw in lines {
            var line = String(raw)
            if pending == nil, line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                line = String(line[line.index(after: semicolon)...])
            }
            if line.hasSuffix("\\") {
                pending = (pending.map { $0 + "\n" } ?? "") + String(line.dropLast())
                continue
            }
            commands.append(pending.map { $0 + "\n" + line } ?? line)
            pending = nil
        }
        if let pending { commands.append(pending) }
        return commands
    }

    /// `- cmd: <escaped>` lines (`\n` newline, `\\` backslash); `when:` and `paths:` are skipped.
    private static func fish(_ lines: [Substring]) -> [String] {
        lines.compactMap { line in
            guard line.hasPrefix("- cmd: ") else { return nil }
            var result = ""
            var escaping = false
            for character in line.dropFirst(7) {
                if escaping {
                    result.append(character == "n" ? "\n" : character)
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
    }
}

/// The History panel's state: loads the history once per `reload`, filters it by `searchText` (every
/// word, case-insensitive). Memory only.
@MainActor
@Observable
public final class ShellHistoryViewModel {
    public enum State: Equatable {
        /// Not read yet (the tab wasn't connected when the panel opened).
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: State = .idle
    public var searchText = ""
    private var all: [String] = []
    @ObservationIgnored private let load: @Sendable () async throws -> String

    public init(load: @escaping @Sendable () async throws -> String) {
        self.load = load
    }

    /// The matching commands, newest first.
    public var commands: [String] {
        let words = searchText.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return all }
        return all.filter { command in
            let lower = command.lowercased()
            return words.allSatisfy { lower.contains($0) }
        }
    }

    public var isLoading: Bool { state == .loading }

    /// Reads the history again; a call while one is running does nothing.
    public func reload() async {
        guard state != .loading else { return }
        state = .loading
        do {
            let output = try await load()
            all = try ShellHistory.parse(output)
            state = .loaded
        } catch {
            all = []
            state = .failed(error.localizedDescription)
        }
    }
}
