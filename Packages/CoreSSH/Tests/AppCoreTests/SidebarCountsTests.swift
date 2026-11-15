import XCTest
import CoreModels
@testable import AppCore

private typealias Host = CoreModels.Host

@MainActor
final class SidebarCountsTests: XCTestCase {
    func testCountsEachSectionsLiveRecords() async throws {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        vault.saveNow(Host(label: "a", address: "a"))
        var gone = vault.saveNow(Host(label: "b", address: "b"))
        gone.deleted = true
        vault.saveNow(gone)
        vault.saveNow(Identity(label: "i", username: "u"))
        vault.saveNow(SSHKey(label: "k", keyType: .ed25519, publicKey: "p", privateKey: "x"))
        vault.saveNow(Snippet(name: "s", script: "x"))
        vault.saveNow(Snippet(name: "t", script: "y"))
        vault.saveNow(KnownHost(hostPort: "a:22", keyType: "ssh-ed25519", fingerprintSHA256: "f"))

        let counts = SidebarCounts(vault: vault)
        XCTAssertEqual(counts.count(for: .hosts), 1, "deleted hosts don't count")
        XCTAssertEqual(counts.count(for: .keychain), 2, "identities and keys")
        XCTAssertEqual(counts.count(for: .snippets), 2)
        XCTAssertEqual(counts.count(for: .knownHosts), 1)
        XCTAssertEqual(counts.count(for: .logs), 0)

        vault.saveNow(Host(label: "c", address: "c"))
        XCTAssertEqual(counts.count(for: .hosts), 2, "follows the vault")
    }
}
