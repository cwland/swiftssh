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
        XCTAssertTrue(OnePasswordAgentConfig.hasOtherEntries(in: text))
        XCTAssertFalse(OnePasswordAgentConfig.hasOtherEntries(in: OnePasswordAgentConfig.toml(vaults: ["Private"])))
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

    func testRefusesToWriteNoVaults() throws {
        let file = OnePasswordAgentConfigFile(home: folder.path)
        XCTAssertThrowsError(try file.write(vaults: [" "])) { error in
            XCTAssertEqual(error as? OnePasswordAgentConfigError, .noVaults)
        }
        XCTAssertNil(try file.read())
    }
}
