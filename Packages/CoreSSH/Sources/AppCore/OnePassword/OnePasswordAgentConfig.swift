import Foundation

/// 1Password's SSH agent config file, `~/.config/1Password/ssh/agent.toml`: which vaults (items,
/// accounts) the agent offers keys from. Without the file the agent offers the Personal, Private or
/// Employee vault; once it exists, only what it lists. 1Password picks up saved changes by itself;
/// a newly created file may need 1Password locked and unlocked once. Holds no secrets.
public enum OnePasswordAgentConfig {
    /// One `[[ssh-keys]]` entry. Each field set narrows the match; nil = not given.
    public struct Entry: Equatable, Sendable {
        public var vault: String?
        public var item: String?
        public var account: String?

        public init(vault: String? = nil, item: String? = nil, account: String? = nil) {
            self.vault = vault
            self.item = item
            self.account = account
        }
    }

    /// The file's path under `home`.
    public static let relativePath = ".config/1Password/ssh/agent.toml"

    /// The file for `vaults`, in the order given, blank vault names and repeats dropped:
    ///
    ///     [[ssh-keys]]
    ///     vault = "SSH Key Vault"
    ///
    ///     [[ssh-keys]]
    ///     vault = "Private"
    ///
    /// then the `kept` entries (`keptEntries(in:)` of the previous file) word for word, under
    /// `keptHeader`. Empty when no vault is left. Names are TOML basic strings (`"` and `\` escaped,
    /// control characters as `\uXXXX`).
    public static func toml(vaults: [String], keeping kept: [String] = []) -> String {
        var seen: Set<String> = []
        let names = vaults.filter { name in
            !name.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(name).inserted
        }
        guard !names.isEmpty else { return "" }
        let text = names.map { "[[ssh-keys]]\nvault = \(quoted($0))\n" }.joined(separator: "\n")
        guard !kept.isEmpty else { return text }
        return text + "\n" + keptHeader + "\n" + kept.map { $0 + "\n" }.joined(separator: "\n")
    }

    /// The comment over the entries kept from the previous file.
    public static let keptHeader = "# Kept from your previous agent.toml"

    /// The `[[ssh-keys]]` entries of an existing file. Comments, blank lines, other tables and keys
    /// other than vault / item / account are skipped; a value in "…" or '…' is read, anything else is
    /// ignored. Never throws: a file it can't follow gives what it could read.
    public static func entries(in text: String) -> [Entry] {
        parse(text).blocks.map(\.entry)
    }

    /// The vaults named by entries that name only a vault (the kind SwiftSSH writes), in order. An entry
    /// with a line this parser can't follow doesn't count (it is kept as written instead).
    public static func vaultNames(in text: String) -> [String] {
        var names: [String] = []
        for block in parse(text).blocks where block.isVaultOnly {
            guard let vault = block.entry.vault, !names.contains(vault) else { continue }
            names.append(vault)
        }
        return names
    }

    /// The `[[ssh-keys]]` entries "Use these vaults" can't write itself (an item, an account, or a line
    /// this parser can't follow), each as its own text: written back unchanged after the vaults.
    public static func keptEntries(in text: String) -> [String] {
        parse(text).blocks.filter { !$0.isVaultOnly }.map { $0.lines.joined(separator: "\n") }
    }

    /// Lines outside the `[[ssh-keys]]` entries that aren't blank or a comment (other tables, inline
    /// tables, top-level keys): "Use these vaults" can't keep them (they stay in the backup).
    public static func unreadLines(in text: String) -> [String] {
        parse(text).unread
    }

    private struct Block {
        var entry = Entry()
        /// The entry's lines as written, from its header; trailing blank and comment lines dropped.
        var lines: [String]
        var allUnderstood = true

        var isVaultOnly: Bool {
            allUnderstood && entry.vault != nil && entry.item == nil && entry.account == nil
        }
    }

    private static func parse(_ text: String) -> (blocks: [Block], unread: [String]) {
        var blocks: [Block] = []
        var unread: [String] = []
        var inSSHKeys = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let raw = String(rawLine)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = stripComment(line).replacingOccurrences(of: " ", with: "")
                inSSHKeys = header == "[[ssh-keys]]"
                if inSSHKeys { blocks.append(Block(lines: [raw])) } else { unread.append(line) }
                continue
            }
            guard inSSHKeys, !blocks.isEmpty else {
                if !line.isEmpty && !line.hasPrefix("#") { unread.append(line) }
                continue
            }
            let index = blocks.count - 1
            blocks[index].lines.append(raw)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (key, value) = keyValue(line) else {
                blocks[index].allUnderstood = false
                continue
            }
            switch key {
            case "vault": blocks[index].entry.vault = value
            case "item": blocks[index].entry.item = value
            case "account": blocks[index].entry.account = value
            default: blocks[index].allUnderstood = false
            }
        }
        for index in blocks.indices {
            while let last = blocks[index].lines.last?.trimmingCharacters(in: .whitespaces),
                  last.isEmpty || last.hasPrefix("#") {
                blocks[index].lines.removeLast()
            }
        }
        return (blocks, unread)
    }

    /// `key = "value"`: a bare or quoted key and a string value; nil when the line is anything else.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        var key = line[..<equals].trimmingCharacters(in: .whitespaces)
        if key.count >= 2, let first = key.first, first == "\"" || first == "'", key.last == first {
            key = String(key.dropFirst().dropLast())
        }
        guard let value = parseString(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (key, value)
    }

    /// `agent.toml.swiftssh-backup-2026-11-15-203000`, from the local time of `date`.
    public static func backupName(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "agent.toml.swiftssh-backup-\(formatter.string(from: date))"
    }

    /// `backupName(date:timeZone:)`, with "-2", "-3"… added while `exists` says that name is taken.
    public static func backupName(date: Date, timeZone: TimeZone = .current, exists: (String) -> Bool) -> String {
        let base = backupName(date: date, timeZone: timeZone)
        var name = base
        var number = 2
        while exists(name) {
            name = "\(base)-\(number)"
            number += 1
        }
        return name
    }

    // MARK: TOML strings

    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\t": result += "\\t"
            default:
                if scalar.properties.generalCategory == .control {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// A TOML basic ("…", with escapes) or literal ('…') string at the start of `text`, followed only
    /// by a comment or nothing; nil otherwise.
    static func parseString(_ text: String) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == quote {
                let rest = text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return rest.isEmpty || rest.hasPrefix("#") ? result : nil
            }
            if quote == "\"", character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
                switch text[index] {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "b": result.append("\u{8}")
                case "f": result.append("\u{C}")
                case "e": result.append("\u{1B}")
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "u", "U":
                    let length = text[index] == "u" ? 4 : 8
                    let start = text.index(after: index)
                    guard let end = text.index(start, offsetBy: length, limitedBy: text.endIndex),
                          let value = UInt32(text[start..<end], radix: 16),
                          let scalar = Unicode.Scalar(value) else { return nil }
                    result.unicodeScalars.append(scalar)
                    index = text.index(before: end)
                default: return nil
                }
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        return String(line[..<hash]).trimmingCharacters(in: .whitespaces)
    }
}

/// Why agent.toml wasn't written.
public enum OnePasswordAgentConfigError: Error, Equatable, LocalizedError {
    /// No vault chosen: an empty file would make the agent offer no keys at all.
    case noVaults
    /// agent.toml is a symbolic link to this path, where nothing is.
    case linkTargetMissing(String)

    public var errorDescription: String? {
        switch self {
        case .noVaults: "Choose at least one vault."
        case .linkTargetMissing(let target):
            "agent.toml is a link to \(target), which doesn\u{2019}t exist. Fix the link, or edit the file there."
        }
    }
}

/// Reads and writes `~/.config/1Password/ssh/agent.toml`.
public struct OnePasswordAgentConfigFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `<home>/.config/1Password/ssh/agent.toml`.
    public init(home: String) {
        self.url = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(OnePasswordAgentConfig.relativePath, isDirectory: false)
    }

    /// The display path, with `~` for the home folder.
    public static let displayPath = "~/" + OnePasswordAgentConfig.relativePath

    /// The file's text; nil when there is no file.
    public func read() throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
    }

    /// What `write` did.
    public struct WriteResult: Equatable, Sendable {
        /// Where the old file was copied; nil when there was none.
        public let backupURL: URL?
    }

    /// Writes the file for `vaults` and the `kept` entries (`OnePasswordAgentConfig.toml`). An existing file
    /// is first copied, byte for byte, to `agent.toml.swiftssh-backup-<date>` next to it (the copy must
    /// succeed, or nothing is written); then the new text replaces it in one step. When agent.toml is a
    /// symbolic link (a dotfile manager's), the link stays and its target gets the new text; a link to
    /// nothing is refused. Creates `~/.config/1Password/ssh` when missing.
    public func write(vaults: [String], keeping kept: [String] = [], date: Date = Date(),
                      timeZone: TimeZone = .current) throws -> WriteResult {
        let text = OnePasswordAgentConfig.toml(vaults: vaults, keeping: kept)
        guard !text.isEmpty else { throw OnePasswordAgentConfigError.noVaults }
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try resolvedDestination()
        var backup: URL?
        if fileManager.fileExists(atPath: destination.path) {
            let name = OnePasswordAgentConfig.backupName(date: date, timeZone: timeZone) { name in
                fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
            }
            let target = folder.appendingPathComponent(name, isDirectory: false)
            try Data(contentsOf: destination).write(to: target, options: .withoutOverwriting)
            backup = target
        }
        try Data(text.utf8).write(to: destination, options: .atomic)
        return WriteResult(backupURL: backup)
    }

    /// Where the text goes: `url`, or the file its symbolic link (chain) ends at.
    private func resolvedDestination() throws -> URL {
        let fileManager = FileManager.default
        var current = url
        for _ in 0..<16 {
            guard let type = try? fileManager.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType,
                  type == .typeSymbolicLink else { return current }
            let link = try fileManager.destinationOfSymbolicLink(atPath: current.path)
            let next = link.hasPrefix("/")
                ? URL(fileURLWithPath: link, isDirectory: false)
                : current.deletingLastPathComponent().appendingPathComponent(link, isDirectory: false)
            guard fileManager.fileExists(atPath: next.path) else {
                throw OnePasswordAgentConfigError.linkTargetMissing(link.hasPrefix("/") ? link : next.standardizedFileURL.path)
            }
            current = next.standardizedFileURL
        }
        return current
    }
}
