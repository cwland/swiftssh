import XCTest
import CoreModels
import SSHCore
import SyncCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// The iPhone/iPad hosts screens: sidebar sections and counts, navigation, the read-only host
/// details and the quick connect filter.
@MainActor
final class CompanionHostsTests: XCTestCase {
    private func makeVault() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "phone" })
    }

    // MARK: Sections and counts

    func testSectionsAreInSidebarOrderWithTitlesAndSymbols() async {
        XCTAssertEqual(CompanionSection.allCases, [.hosts, .snippets, .knownHosts, .keys, .settings])
        XCTAssertEqual(CompanionSection.allCases.map(\.title), ["Hosts", "Snippets", "Known Hosts", "Keys", "Settings"])
        for section in CompanionSection.allCases { XCTAssertFalse(section.symbol.isEmpty) }
    }

    func testCountsComeFromTheVaultAndTheImportedKeys() async throws {
        let vault = try await makeVault()
        _ = try await vault.save(SavedHost(label: "a", address: "a"))
        let gone = try await vault.save(SavedHost(label: "b", address: "b"))
        try await vault.delete(SavedHost.self, id: gone.id)
        _ = try await vault.save(Snippet(name: "s", script: "ls"))
        _ = try await vault.save(KnownHost(hostPort: "a:22", keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:x"))
        let counts = CompanionSidebarCounts(vault: vault, importedKeyCount: 2)
        XCTAssertEqual(counts.count(for: .hosts), 1)
        XCTAssertEqual(counts.count(for: .snippets), 1)
        XCTAssertEqual(counts.count(for: .knownHosts), 1)
        XCTAssertEqual(counts.count(for: .keys), 2)
        XCTAssertNil(counts.count(for: .settings))
    }

    // MARK: Navigation

    func testShowingASectionSetsThePhonePath() async {
        let navigation = CompanionNavigation()
        XCTAssertEqual(navigation.section, .hosts)
        XCTAssertEqual(navigation.phonePath, [])
        navigation.show(.keys)
        XCTAssertEqual(navigation.section, .keys)
        XCTAssertEqual(navigation.phonePath, [.keys])
        navigation.show(.hosts)
        XCTAssertEqual(navigation.phonePath, [])
    }

    func testSearchRequestShowsHostsAndCountsUp() async {
        let navigation = CompanionNavigation()
        navigation.show(.settings)
        navigation.requestSearch()
        XCTAssertEqual(navigation.section, .hosts)
        XCTAssertEqual(navigation.phonePath, [])
        XCTAssertEqual(navigation.searchRequests, 1)
        navigation.requestSearch()
        XCTAssertEqual(navigation.searchRequests, 2)
    }

    func testOpeningAKeyFileShowsKeysWithTheFileWaiting() async {
        let navigation = CompanionNavigation()
        navigation.openKeyFile(data: Data("key".utf8), name: "laptop.key")
        XCTAssertEqual(navigation.section, .keys)
        XCTAssertEqual(navigation.phonePath, [.keys])
        let file = navigation.takePendingKeyFile()
        XCTAssertEqual(file?.data, Data("key".utf8))
        XCTAssertEqual(file?.name, "laptop.key")
        XCTAssertNil(navigation.takePendingKeyFile(), "taken once")
    }

    // MARK: Host details (read-only)

    func testDetailsOfAPasswordHost() async throws {
        let vault = try await makeVault()
        let group = try await vault.save(HostGroup(name: "Lab", defaultPort: 2222))
        let host = try await vault.save(SavedHost(label: "nas", address: " nas.lan ", groupID: group.id,
                                                  username: "cory", password: "secret"))
        let details = try XCTUnwrap(CompanionHostDetails(hostID: host.id, vault: vault))
        XCTAssertEqual(details.label, "nas")
        XCTAssertEqual(details.address, "nas.lan")
        XCTAssertEqual(details.port, 2222)
        XCTAssertEqual(details.username, "cory")
        XCTAssertEqual(details.groupPath, "Lab")
        XCTAssertEqual(details.signIn, "Saved password")
        XCTAssertFalse(details.signIn.contains("secret"))
    }

    func testDetailsOfAOnePasswordPasswordNameTheAutoFill() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "web", address: "web", username: "root",
                                                  password: "op://Private/Web server/password"))
        let details = try XCTUnwrap(CompanionHostDetails(hostID: host.id, vault: vault))
        XCTAssertEqual(details.signIn, "Password from 1Password (\u{201C}Web server\u{201D}), filled with AutoFill")
    }

    func testDetailsOfAnAgentHostThroughAnIdentity() async throws {
        let vault = try await makeVault()
        let identity = try await vault.save(Identity(label: "Me", username: "alice",
                                                     agentKey: AgentKeyChoice(publicKey: nil)))
        let host = try await vault.save(SavedHost(label: "pi", address: "pi", identityID: identity.id))
        let details = try XCTUnwrap(CompanionHostDetails(hostID: host.id, vault: vault))
        XCTAssertEqual(details.username, "alice")
        XCTAssertEqual(details.signIn, "Identity \u{201C}Me\u{201D}: SSH key from 1Password (uses the keys imported on this device)")
        XCTAssertNil(details.groupPath)
    }

    func testDetailsOfAnRSAKeyHostSayItIsNotSupported() async throws {
        let vault = try await makeVault()
        let key = try await vault.save(SSHKey(label: "old", keyType: .rsa, publicKey: "ssh-rsa AAAA", privateKey: "PEM"))
        let host = try await vault.save(SavedHost(label: "legacy", address: "l", username: "root", sshKeyID: key.id))
        let details = try XCTUnwrap(CompanionHostDetails(hostID: host.id, vault: vault))
        XCTAssertEqual(details.signIn, "SSH key \u{201C}old\u{201D} (RSA keys aren\u{2019}t supported on iPhone/iPad yet)")
        XCTAssertFalse(details.signIn.contains("PEM"))
    }

    func testDetailsWithoutCredentialsAskForAPassword() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "", address: "x", username: "root"))
        let details = try XCTUnwrap(CompanionHostDetails(hostID: host.id, vault: vault))
        XCTAssertEqual(details.label, "Untitled host")
        XCTAssertEqual(details.port, 22)
        XCTAssertEqual(details.signIn, "Password, asked when connecting")
    }

    func testDetailsOfAMissingHostAreNil() async throws {
        let vault = try await makeVault()
        XCTAssertNil(CompanionHostDetails(hostID: UUID(), vault: vault))
    }

    func testNestedGroupPath() async throws {
        let vault = try await makeVault()
        let outer = try await vault.save(HostGroup(name: "Home"))
        let inner = try await vault.save(HostGroup(name: "Rack", parentID: outer.id))
        let host = try await vault.save(SavedHost(label: "h", address: "h", groupID: inner.id, username: "u"))
        XCTAssertEqual(CompanionHostDetails(hostID: host.id, vault: vault)?.groupPath, "Home \u{203A} Rack")
    }

    // MARK: Quick connect filter

    private func hosts(_ specs: [(String, String)]) -> [SavedHost] {
        specs.map { SavedHost(label: $0.0, address: $0.1) }
    }

    func testQuickFilterRanksLabelPrefixThenWordThenContainsThenAddress() async {
        let all = hosts([("Backup NAS", "10.0.0.9"), ("nas", "192.168.1.2"), ("Synas box", "s"),
                         ("printer", "nas-printer.lan"), ("router", "r")])
        XCTAssertEqual(HostQuickFilter.matches("nas", in: all).map(\.label),
                       ["nas", "Backup NAS", "Synas box", "printer"])
    }

    func testQuickFilterWithoutTextListsEveryHostByName() async {
        let all = hosts([("b", "1"), ("A", "2"), ("c", "3")])
        XCTAssertEqual(HostQuickFilter.matches("  ", in: all).map(\.label), ["A", "b", "c"])
    }

    func testQuickFilterSkipsDeletedHostsAndHonoursTheLimit() async {
        var all = hosts((1...10).map { ("web\($0)", "w") })
        all[0].deleted = true
        let found = HostQuickFilter.matches("web", in: all, limit: 3)
        XCTAssertEqual(found.count, 3)
        XCTAssertFalse(found.contains { $0.deleted })
    }
}
