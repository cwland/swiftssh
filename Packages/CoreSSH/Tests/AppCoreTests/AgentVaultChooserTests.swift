import XCTest
import Synchronization
import SSHCore
@testable import AppCore

/// An `op` that answers vault and item lists only; it records what it was asked.
private final class VaultListingOP: OnePasswordCLI, Sendable {
    let vaults: Result<[OnePasswordVault], OnePasswordError>
    let keyItems: Result<[OnePasswordItemSummary], OnePasswordError>
    let calls = Mutex<[String]>([])

    init(vaults: Result<[OnePasswordVault], OnePasswordError>,
         keyItems: Result<[OnePasswordItemSummary], OnePasswordError> = .success([])) {
        self.vaults = vaults
        self.keyItems = keyItems
    }

    func read(reference: String) async throws(OnePasswordError) -> String {
        calls.withLock { $0.append("read") }
        throw .failed("read must never be called")
    }
    func listItems() async throws(OnePasswordError) -> [OnePasswordItemSummary] { throw .failed("unused") }
    func fields(itemID: String, vault: String) async throws(OnePasswordError) -> [OnePasswordField] { [] }
    func check() async throws(OnePasswordError) {}
    func listVaults() async throws(OnePasswordError) -> [OnePasswordVault] {
        calls.withLock { $0.append("vaults") }
        return try vaults.get()
    }
    func listItems(categories: [String]) async throws(OnePasswordError) -> [OnePasswordItemSummary] {
        calls.withLock { $0.append("items:\(categories.joined(separator: ","))") }
        return try keyItems.get()
    }
}

private final class AgentAnswers: Sendable {
    let answers = Mutex<[Result<[AgentKey], SSHAgentError>]>([])
    let delays = Mutex<[Duration]>([])

    func next() throws -> [AgentKey] {
        try answers.withLock { $0.isEmpty ? .success([]) : $0.removeFirst() }.get()
    }
}

final class AgentVaultChooserTests: XCTestCase {
    private var home: URL!
    private let key = AgentKey(publicKeyLine: "ssh-ed25519 AAAAkey Homelab key", type: "ssh-ed25519",
                               comment: "Homelab key", fingerprint: "SHA256:abc")
    private let vaults = [OnePasswordVault(id: "v-private", name: "Private"),
                          OnePasswordVault(id: "v-ssh", name: "SSH Key Vault"),
                          OnePasswordVault(id: "v-shared", name: "Shared")]

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("chooser-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private var file: OnePasswordAgentConfigFile { OnePasswordAgentConfigFile(home: home.path) }

    private func sshItem(_ vaultID: String) -> OnePasswordItemSummary {
        OnePasswordItemSummary(id: UUID().uuidString, title: "key", vault: "?", vaultID: vaultID, category: "SSH_KEY")
    }

    @MainActor
    private func chooser(_ op: VaultListingOP?, agent: AgentAnswers = AgentAnswers()) -> AgentVaultChooser {
        AgentVaultChooser(cli: { op }, file: file, listAgentKeys: { try agent.next() },
                          sleep: { delay in agent.delays.withLock { $0.append(delay) } },
                          now: { Date(timeIntervalSince1970: 1_794_775_810) })
    }

    @MainActor
    func testPreselectsVaultsWithSSHKeysAndTheDefaultVaultWithoutAFile() async {
        let op = VaultListingOP(vaults: .success(vaults), keyItems: .success([sshItem("v-ssh"), sshItem("v-ssh")]))
        let model = chooser(op)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.rows.map(\.name), ["Private", "SSH Key Vault", "Shared"])
        XCTAssertEqual(model.rows.map(\.isSelected), [true, true, false])
        XCTAssertEqual(model.rows.map(\.sshKeyCount), [0, 2, 0])
        XCTAssertNil(model.existingText)
        XCTAssertEqual(op.calls.withLock { $0 }, ["vaults", "items:SSH Key"], "never reads a secret")
    }

    @MainActor
    func testPreselectsWhatAnExistingFileNames() async throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "[[ssh-keys]]\nvault = \"Shared\"\n\n[[ssh-keys]]\nvault = \"Old Vault\"\n"
        try Data(old.utf8).write(to: file.url)
        let model = chooser(VaultListingOP(vaults: .success(vaults), keyItems: .failure(.failed("nope"))))
        await model.load()
        XCTAssertEqual(model.existingText, old)
        XCTAssertEqual(model.rows.map(\.name), ["Private", "SSH Key Vault", "Shared", "Old Vault"])
        // With a file, Private is no longer implied; the SSH key counts are unknown.
        XCTAssertEqual(model.rows.map(\.isSelected), [false, false, true, true])
        XCTAssertEqual(model.rows.map(\.sshKeyCount), [nil, nil, nil, nil])
        XCTAssertEqual(model.keptEntries, [])
        XCTAssertEqual(model.removals, [])
        XCTAssertFalse(model.needsConfirmation)
    }

    /// Review I5: with a file, only what it names is chosen; vaults holding SSH keys are a hint only, and
    /// an item-scoped entry is written back as it was.
    @MainActor
    func testWithAFileOnlyItsVaultsAreChosenAndItemEntriesAreKept() async throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "[[ssh-keys]]\nvault = \"Private\"\n[[ssh-keys]]\nitem = \"Deploy key\"\nvault = \"Team Infra\"\n"
        try Data(old.utf8).write(to: file.url)
        let vaults = [OnePasswordVault(id: "v-private", name: "Private"), OnePasswordVault(id: "v-team", name: "Team Infra")]
        let items = (0..<14).map { _ in sshItem("v-team") }
        let model = chooser(VaultListingOP(vaults: .success(vaults), keyItems: .success(items)))
        await model.load()
        XCTAssertEqual(model.rows.map(\.isSelected), [true, false])
        XCTAssertEqual(model.rows.map(\.sshKeyCount), [0, 14])
        XCTAssertEqual(model.keptEntries, ["[[ssh-keys]]\nitem = \"Deploy key\"\nvault = \"Team Infra\""])
        XCTAssertFalse(model.needsConfirmation)
        await model.apply()
        let expected = OnePasswordAgentConfig.toml(vaults: ["Private"], keeping: model.keptEntries)
        XCTAssertEqual(try file.read(), expected)
        XCTAssertTrue(expected.contains("item = \"Deploy key\""))
        XCTAssertEqual(model.existingText, expected)
    }

    /// Taking a vault (or a line it can't read) out of the file needs a yes first.
    @MainActor
    func testRemovingEntriesAsksFirst() async throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "[[ssh-keys]]\nvault = \"Private\"\n[[ssh-keys]]\nvault = \"v-shared\"\n[other]\nx = 1\n"
        try Data(old.utf8).write(to: file.url)
        let model = chooser(VaultListingOP(vaults: .success(vaults)))
        await model.load()
        XCTAssertEqual(model.selectedNames, ["Private", "Shared"], "a vault named by its ID is found")
        XCTAssertEqual(model.removals, ["The line \u{201C}[other]\u{201D}", "The line \u{201C}x = 1\u{201D}"])
        model.toggle("v-private")
        XCTAssertEqual(model.removals, ["The vault \u{201C}Private\u{201D}", "The line \u{201C}[other]\u{201D}",
                                        "The line \u{201C}x = 1\u{201D}"])
        XCTAssertTrue(model.needsConfirmation)
        XCTAssertTrue(model.confirmationMessage.contains("The vault \u{201C}Private\u{201D}"), model.confirmationMessage)
        await model.apply()
        XCTAssertTrue(model.isAskingToConfirm)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(try file.read(), old, "nothing written before the yes")
        await model.apply(confirmed: true)
        XCTAssertFalse(model.isAskingToConfirm)
        XCTAssertEqual(try file.read(), OnePasswordAgentConfig.toml(vaults: ["Shared"]))
        XCTAssertNotNil(model.backupURL)
    }

    /// Review I4: a file that can't be read is shown as such: no defaults, and a yes before replacing it.
    @MainActor
    func testUnreadableFileIsNotTreatedAsNoFile() async throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0x5B, 0x5B, 0xFF, 0xFE, 0x5D, 0x5D, 0x0A])
        try bytes.write(to: file.url)
        let model = chooser(VaultListingOP(vaults: .success(vaults)))
        await model.load()
        XCTAssertNil(model.existingText)
        let reason = try XCTUnwrap(model.existingReadError)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(model.rows.map(\.isSelected), [false, false, false], "no defaults: the file exists")
        model.toggle("v-ssh")
        XCTAssertTrue(model.needsConfirmation)
        XCTAssertTrue(model.confirmationMessage.hasPrefix("~/.config/1Password/ssh/agent.toml exists but couldn\u{2019}t be read"),
                      model.confirmationMessage)
        await model.apply()
        XCTAssertTrue(model.isAskingToConfirm)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        await model.apply(confirmed: true)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(model.backupURL)), bytes, "the backup holds the old bytes")
        XCTAssertEqual(try file.read(), OnePasswordAgentConfig.toml(vaults: ["SSH Key Vault"]))
        XCTAssertNil(model.existingReadError)
    }

    @MainActor
    func testWithoutOpVaultsCanBeTyped() async {
        let model = chooser(nil)
        await model.load()
        XCTAssertEqual(model.phase, .listFailed(.cliNotFound))
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.addVault(named: "  "))
        XCTAssertTrue(model.addVault(named: " SSH Key Vault "))
        XCTAssertTrue(model.addVault(named: "Private"))
        XCTAssertTrue(model.addVault(named: "Private"))
        XCTAssertEqual(model.selectedNames, ["SSH Key Vault", "Private"])
        XCTAssertTrue(model.canApply)
    }

    @MainActor
    func testListFailureKeepsTheFilesVaults() async throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[[ssh-keys]]\nvault = \"Private\"\n".utf8).write(to: file.url)
        let model = chooser(VaultListingOP(vaults: .failure(.integrationOff(details: "No accounts configured"))))
        await model.load()
        XCTAssertEqual(model.phase, .listFailed(.integrationOff(details: "No accounts configured")))
        XCTAssertEqual(model.selectedNames, ["Private"])
    }

    /// Cory's fix (c), done by the app: writes the file, waits, and the agent now offers the key.
    @MainActor
    func testUseTheseVaultsWritesTheFileAndRechecks() async throws {
        let agent = AgentAnswers()
        agent.answers.withLock { $0 = [.success([key])] }
        let model = chooser(VaultListingOP(vaults: .success(vaults), keyItems: .success([sshItem("v-ssh")])), agent: agent)
        await model.load()
        model.toggle("v-shared")
        model.toggle("v-shared")
        XCTAssertEqual(model.preview, OnePasswordAgentConfig.toml(vaults: ["Private", "SSH Key Vault"]))
        await model.apply()
        XCTAssertEqual(try file.read(), OnePasswordAgentConfig.toml(vaults: ["Private", "SSH Key Vault"]))
        XCTAssertNil(model.backupURL, "there was no file to back up")
        XCTAssertEqual(agent.delays.withLock { $0 }, [.seconds(3)])
        XCTAssertEqual(model.phase, .done(.offers([key])))
        XCTAssertEqual(AgentVaultChooser.AgentRecheck.offers([key]).message, "Done. The agent now offers 1 key.")
    }

    @MainActor
    func testUseTheseVaultsBacksUpTheOldFile() async throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "[[ssh-keys]]\nitem = \"GitHub key\"\n"
        try Data(old.utf8).write(to: file.url)
        let model = chooser(VaultListingOP(vaults: .success(vaults)))
        await model.load()
        XCTAssertEqual(model.keptEntries, ["[[ssh-keys]]\nitem = \"GitHub key\""])
        model.toggle("v-ssh")
        await model.apply()
        let backup = try XCTUnwrap(model.backupURL)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("agent.toml.swiftssh-backup-2026-11-15-"), backup.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), old)
        XCTAssertEqual(model.existingText, OnePasswordAgentConfig.toml(vaults: ["SSH Key Vault"],
                                                                        keeping: ["[[ssh-keys]]\nitem = \"GitHub key\""]))
        XCTAssertEqual(model.phase, .done(.offersNone))
        XCTAssertTrue(AgentVaultChooser.AgentRecheck.offersNone.message.contains("Lock 1Password and unlock it again"))
    }

    @MainActor
    func testRecheckReportsAnAgentFailure() async {
        let agent = AgentAnswers()
        agent.answers.withLock { $0 = [.failure(.timedOut)] }
        let model = chooser(nil, agent: agent)
        await model.recheck()
        XCTAssertEqual(model.phase, .done(.failed(SSHAgentError.timedOut.errorDescription!)))
        XCTAssertEqual(agent.delays.withLock { $0 }, [], "a manual recheck doesn't wait")
    }

    @MainActor
    func testSaveFailureIsShown() async throws {
        // A folder where the file should be: writing fails.
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        let model = chooser(nil)
        model.addVault(named: "Private")
        await model.apply()
        guard case .saveFailed(let message) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(message.hasPrefix("Couldn\u{2019}t save ~/.config/1Password/ssh/agent.toml"), message)
    }

    @MainActor
    func testNothingChosenCantBeApplied() async {
        let model = chooser(VaultListingOP(vaults: .success([OnePasswordVault(id: "v", name: "Work")])))
        await model.load()
        XCTAssertEqual(model.selectedNames, [])
        XCTAssertFalse(model.canApply)
        await model.apply()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(try file.read())
    }
}
