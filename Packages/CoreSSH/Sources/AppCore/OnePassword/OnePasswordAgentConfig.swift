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
    /// Names are TOML basic strings (`"` and `\` escaped, control characters as `\uXXXX`).
    public static func toml(vaults: [String]) -> String {
        var seen: Set<String> = []
        let names = vaults.filter { name in
            !name.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(name).inserted
        }
        return names.map { "[[ssh-keys]]\nvault = \(quoted($0))\n" }.joined(separator: "\n")
    }

    /// The `[[ssh-keys]]` entries of an existing file. Comments, blank lines, other tables and keys
    /// other than vault / item / account are skipped; a value in "…" or '…' is read, anything else is
    /// ignored. Never throws: a file it can't follow gives what it could read.
    public static func entries(in text: String) -> [Entry] {
        var result: [Entry] = []
        var inSSHKeys = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                let header = stripComment(line).replacingOccurrences(of: " ", with: "")
                inSSHKeys = header == "[[ssh-keys]]"
                if inSSHKeys { result.append(Entry()) }
                continue
            }
            guard inSSHKeys, !result.isEmpty, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard let value = parseString(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)) else { continue }
            switch key {
            case "vault": result[result.count - 1].vault = value
            case "item": result[result.count - 1].item = value
            case "account": result[result.count - 1].account = value
            default: break
            }
        }
        return result
    }

    /// The vaults named by entries that name only a vault (the kind SwiftSSH writes), in order.
    public static func vaultNames(in text: String) -> [String] {
        var names: [String] = []
        for entry in entries(in: text) {
            guard let vault = entry.vault, entry.item == nil, entry.account == nil, !names.contains(vault) else { continue }
            names.append(vault)
        }
        return names
    }

    /// Whether the file has entries "Use these vaults" can't keep (an item or an account); they stay
    /// in the backup.
    public static func hasOtherEntries(in text: String) -> Bool {
        entries(in: text).contains { $0.item != nil || $0.account != nil || $0.vault == nil }
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

    public var errorDescription: String? {
        switch self {
        case .noVaults: "Choose at least one vault."
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

    /// Writes the file for `vaults` (`OnePasswordAgentConfig.toml`). An existing file is first copied to
    /// `agent.toml.swiftssh-backup-<date>` next to it (the copy must succeed, or nothing is written);
    /// then the new text replaces it in one step. Creates `~/.config/1Password/ssh` when missing.
    public func write(vaults: [String], date: Date = Date(), timeZone: TimeZone = .current) throws -> WriteResult {
        let text = OnePasswordAgentConfig.toml(vaults: vaults)
        guard !text.isEmpty else { throw OnePasswordAgentConfigError.noVaults }
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var backup: URL?
        if fileManager.fileExists(atPath: url.path) {
            let name = OnePasswordAgentConfig.backupName(date: date, timeZone: timeZone) { name in
                fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
            }
            let target = folder.appendingPathComponent(name, isDirectory: false)
            try fileManager.copyItem(at: url, to: target)
            backup = target
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        return WriteResult(backupURL: backup)
    }
}
