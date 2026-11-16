import XCTest
@testable import AppCore

final class OnePasswordAgentConfigTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-toml-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Generating

    /// Exactly what Cory wrote by hand on his second Mac.
    func testGeneratesCorysFile() {
        XCTAssertEqual(OnePasswordAgentConfig.toml(vaults: ["SSH Key Vault", "Private"]), """
        [[ssh-keys]]
        vault = "SSH Key Vault"

        [[ssh-keys]]
        vault = "Private"

        """)
    }

    func testDropsBlanksAndRepeatsAndEscapes() {
        XCTAssertEqual(OnePasswordAgentConfig.toml(vaults: ["Private", " ", "Private", "Cory's \"keys\" \\ work"]), """
        [[ssh-keys]]
        vault = "Private"

        [[ssh-keys]]
        vault = "Cory's \\"keys\\" \\\\ work"

        """)
        XCTAssertEqual(OnePasswordAgentConfig.toml(vaults: []), "")
        XCTAssertEqual(OnePasswordAgentConfig.quoted("a\tb\u{7}"), "\"a\\tb\\u0007\"")
    }

    // MARK: Parsing

    func testParsesWhatItWrites() {
        let names = ["SSH Key Vault", "Private", "Cory's \"keys\" \\ work", "Ünïcode ✓"]
        XCTAssertEqual(OnePasswordAgentConfig.vaultNames(in: OnePasswordAgentConfig.toml(vaults: names)), names)
    }

    func testParsesHandWrittenFiles() {
        let text = """
        # Keys for work and home
        [[ssh-keys]]
        vault = "SSH Key Vault"   # the custom one

        [[ ssh-keys ]]
          vault='Private'

        [[ssh-keys]]
        item = "GitHub key"
        vault = "Work"

        [[ssh-keys]]
        account = "my.1password.com"

        [something-else]
        vault = "Ignored"

        [[ssh-keys]]
        vault = not-a-string
        """
        XCTAssertEqual(OnePasswordAgentConfig.entries(in: text), [
            .init(vault: "SSH Key Vault"),
            .init(vault: "Private"),
            .init(vault: "Work", item: "GitHub key"),
            .init(account: "my.1password.com"),
            .init(),
        ])
        XCTAssertEqual(OnePasswordAgentConfig.vaultNames(in: text), ["SSH Key Vault", "Private"])
        // Entries that aren't a plain vault are kept as written; the other table can't be.
        XCTAssertEqual(OnePasswordAgentConfig.keptEntries(in: text), [
            "[[ssh-keys]]\nitem = \"GitHub key\"\nvault = \"Work\"",
            "[[ssh-keys]]\naccount = \"my.1password.com\"",
            "[[ssh-keys]]\nvault = not-a-string",
        ])
        XCTAssertEqual(OnePasswordAgentConfig.unreadLines(in: text), ["[something-else]", "vault = \"Ignored\""])
        XCTAssertEqual(OnePasswordAgentConfig.keptEntries(in: OnePasswordAgentConfig.toml(vaults: ["Private"])), [])
        XCTAssertEqual(OnePasswordAgentConfig.unreadLines(in: OnePasswordAgentConfig.toml(vaults: ["Private"])), [])
    }

    /// Review I5: an item-scoped entry survives "Use these vaults", word for word, and only once.
    func testWritesKeptEntriesAfterTheVaults() {
        let old = """
        [[ssh-keys]]
        vault = "Private"

        [[ssh-keys]]
        # CI only
        item = "Deploy key"
        vault = "Team Infra"

        """
        let kept = OnePasswordAgentConfig.keptEntries(in: old)
        XCTAssertEqual(kept, ["[[ssh-keys]]\n# CI only\nitem = \"Deploy key\"\nvault = \"Team Infra\""])
        XCTAssertEqual(OnePasswordAgentConfig.vaultNames(in: old), ["Private"], "the item's vault isn't a vault entry")
        let written = OnePasswordAgentConfig.toml(vaults: ["Private", "SSH Key Vault"], keeping: kept)
        XCTAssertEqual(written, """
        [[ssh-keys]]
        vault = "Private"

        [[ssh-keys]]
        vault = "SSH Key Vault"

        # Kept from your previous agent.toml
        [[ssh-keys]]
        # CI only
        item = "Deploy key"
        vault = "Team Infra"

        """)
        XCTAssertEqual(OnePasswordAgentConfig.keptEntries(in: written), kept)
        XCTAssertEqual(OnePasswordAgentConfig.toml(vaults: ["Private", "SSH Key Vault"],
                                                   keeping: OnePasswordAgentConfig.keptEntries(in: written)), written)
        XCTAssertEqual(OnePasswordAgentConfig.toml(vaults: [], keeping: kept), "", "no vault: nothing to write")
    }

    /// Review M4: quoted keys and the other TOML escapes are read; forms it can't follow are reported.
    func testQuotedKeysEscapesAndUnreadForms() {
        let text = """
        [[ssh-keys]]
        "vault" = "Quoted"

        [[ssh-keys]]
        'vault' = "Tab\\b\\f\\e"
        """
        XCTAssertEqual(OnePasswordAgentConfig.vaultNames(in: text), ["Quoted", "Tab\u{8}\u{C}\u{1B}"])
        XCTAssertEqual(OnePasswordAgentConfig.keptEntries(in: text), [])
        let inline = "ssh-keys = [{ vault = \"Inline\" }]\nvault = \"Top\"\n"
        XCTAssertEqual(OnePasswordAgentConfig.unreadLines(in: inline), ["ssh-keys = [{ vault = \"Inline\" }]", "vault = \"Top\""])
        // A vault entry with a line it can't follow is kept as written, not turned into a plain vault.
        let odd = "[[ssh-keys]]\nvault = \"Work\"\nfuture-option = true\n"
        XCTAssertEqual(OnePasswordAgentConfig.vaultNames(in: odd), [])
        XCTAssertEqual(OnePasswordAgentConfig.keptEntries(in: odd), ["[[ssh-keys]]\nvault = \"Work\"\nfuture-option = true"])
    }

    func testParsesCRLFAndEscapes() {
        let text = "[[ssh-keys]]\r\nvault = \"A\\u00e9\\\"B\"\r\n"
        XCTAssertEqual(OnePasswordAgentConfig.vaultNames(in: text), ["A\u{e9}\"B"])
        XCTAssertNil(OnePasswordAgentConfig.parseString("\"unterminated"))
        XCTAssertNil(OnePasswordAgentConfig.parseString("\"a\" trailing"))
        XCTAssertNil(OnePasswordAgentConfig.parseString("\"bad \\q escape\""))
        XCTAssertEqual(OnePasswordAgentConfig.parseString("'C:\\no\\escapes'"), "C:\\no\\escapes")
    }

    func testEmptyOrGarbageFile() {
        XCTAssertEqual(OnePasswordAgentConfig.entries(in: ""), [])
        XCTAssertEqual(OnePasswordAgentConfig.vaultNames(in: "vault = \"outside a table\"\n%%%"), [])
    }

    // MARK: Backup names

    func testBackupName() {
        let date = Date(timeIntervalSince1970: 1_794_775_810) // 2026-11-15 20:50:10 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(OnePasswordAgentConfig.backupName(date: date, timeZone: utc),
                       "agent.toml.swiftssh-backup-2026-11-15-205010")
        let chicago = TimeZone(identifier: "America/Chicago")!
        XCTAssertEqual(OnePasswordAgentConfig.backupName(date: date, timeZone: chicago),
                       "agent.toml.swiftssh-backup-2026-11-15-145010")
        let taken: Set<String> = ["agent.toml.swiftssh-backup-2026-11-15-205010", "agent.toml.swiftssh-backup-2026-11-15-205010-2"]
        XCTAssertEqual(OnePasswordAgentConfig.backupName(date: date, timeZone: utc, exists: taken.contains),
                       "agent.toml.swiftssh-backup-2026-11-15-205010-3")
    }

    // MARK: The file

    func testFilePath() {
        XCTAssertEqual(OnePasswordAgentConfigFile(home: "/Users/cory").url.path,
                       "/Users/cory/.config/1Password/ssh/agent.toml")
        XCTAssertEqual(OnePasswordAgentConfigFile.displayPath, "~/.config/1Password/ssh/agent.toml")
    }

    func testWritesANewFileAndItsFolders() throws {
        let file = OnePasswordAgentConfigFile(home: folder.path)
        XCTAssertNil(try file.read())
        let result = try file.write(vaults: ["SSH Key Vault", "Private"])
        XCTAssertNil(result.backupURL)
        XCTAssertEqual(try file.read(), OnePasswordAgentConfig.toml(vaults: ["SSH Key Vault", "Private"]))
    }

    func testBacksUpAnExistingFileBeforeWriting() throws {
        let file = OnePasswordAgentConfigFile(home: folder.path)
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "[[ssh-keys]]\nitem = \"GitHub key\"\n"
        try Data(old.utf8).write(to: file.url)
        let date = Date(timeIntervalSince1970: 1_794_775_810)
        let utc = TimeZone(identifier: "UTC")!

        let first = try file.write(vaults: ["Private"], date: date, timeZone: utc)
        XCTAssertEqual(first.backupURL?.lastPathComponent, "agent.toml.swiftssh-backup-2026-11-15-205010")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(first.backupURL), encoding: .utf8), old)
        XCTAssertEqual(try file.read(), OnePasswordAgentConfig.toml(vaults: ["Private"]))

        // Same second again: the first backup is kept, the new one gets "-2".
        let second = try file.write(vaults: ["SSH Key Vault"], date: date, timeZone: utc)
        XCTAssertEqual(second.backupURL?.lastPathComponent, "agent.toml.swiftssh-backup-2026-11-15-205010-2")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(first.backupURL), encoding: .utf8), old)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(second.backupURL), encoding: .utf8),
                       OnePasswordAgentConfig.toml(vaults: ["Private"]))
    }

    func testWritesKeptEntries() throws {
        let file = OnePasswordAgentConfigFile(home: folder.path)
        let kept = ["[[ssh-keys]]\nitem = \"Deploy key\""]
        _ = try file.write(vaults: ["Private"], keeping: kept)
        XCTAssertEqual(try file.read(), OnePasswordAgentConfig.toml(vaults: ["Private"], keeping: kept))
    }

    /// Review I6: a dotfile manager's link stays a link; the new text goes to its target, and the backup
    /// is a real copy of the old bytes, not another link.
    func testWritesThroughALinkAndBacksUpTheBytes() throws {
        let file = OnePasswordAgentConfigFile(home: folder.path)
        let fileManager = FileManager.default
        let dotfiles = folder.appendingPathComponent("dotfiles", isDirectory: true)
        try fileManager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("agent.toml")
        let old = "[[ssh-keys]]\nvault = \"Private\"\n"
        try Data(old.utf8).write(to: target)
        try fileManager.createSymbolicLink(atPath: file.url.path, withDestinationPath: "../../../dotfiles/agent.toml")

        let result = try file.write(vaults: ["SSH Key Vault"])
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: file.url.path), "../../../dotfiles/agent.toml",
                       "the link is left alone")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), OnePasswordAgentConfig.toml(vaults: ["SSH Key Vault"]))
        let backup = try XCTUnwrap(result.backupURL)
        XCTAssertEqual(backup.deletingLastPathComponent().standardizedFileURL, file.url.deletingLastPathComponent().standardizedFileURL)
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), old)
    }

    func testRefusesALinkToNothing() throws {
        let file = OnePasswordAgentConfigFile(home: folder.path)
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let missing = folder.appendingPathComponent("gone/agent.toml").path
        try FileManager.default.createSymbolicLink(atPath: file.url.path, withDestinationPath: missing)
        XCTAssertThrowsError(try file.write(vaults: ["Private"])) { error in
            XCTAssertEqual(error as? OnePasswordAgentConfigError, .linkTargetMissing(missing))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "agent.toml is a link to \(missing), which doesn\u{2019}t exist. Fix the link, or edit the file there.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    /// Review I4: a file that exists but can't be read is an error, never "no file".
    func testReadReportsAFileItCantRead() throws {
        let file = OnePasswordAgentConfigFile(home: folder.path)
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x5B, 0xFF, 0xFE, 0x00, 0x5D]).write(to: file.url)
        XCTAssertThrowsError(try file.read())
    }

    func testRefusesToWriteNoVaults() throws {
        let file = OnePasswordAgentConfigFile(home: folder.path)
        XCTAssertThrowsError(try file.write(vaults: [" "])) { error in
            XCTAssertEqual(error as? OnePasswordAgentConfigError, .noVaults)
        }
        XCTAssertNil(try file.read())
    }
}
