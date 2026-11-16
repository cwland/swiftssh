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
        XCTAssertFalse(model.existingHasOtherEntries)
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
        XCTAssertTrue(model.existingHasOtherEntries)
        model.toggle("v-ssh")
        await model.apply()
        let backup = try XCTUnwrap(model.backupURL)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("agent.toml.swiftssh-backup-2026-11-15-"), backup.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), old)
        XCTAssertEqual(model.existingText, OnePasswordAgentConfig.toml(vaults: ["SSH Key Vault"]))
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
