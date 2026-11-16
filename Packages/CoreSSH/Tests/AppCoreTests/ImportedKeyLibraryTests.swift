import XCTest
import CoreModels
import SSHCore
import SyncCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

@MainActor
final class ImportedKeyLibraryTests: XCTestCase {
    private var storage: InMemoryImportedKeyStorage!
    private var library: ImportedKeyLibrary!

    override func setUp() async throws {
        storage = InMemoryImportedKeyStorage()
        library = ImportedKeyLibrary(storage: storage, now: { Date(timeIntervalSince1970: 1_000) })
    }

    private func assertImportFails(_ text: String, passphrase: String? = nil, _ expected: ImportedKeyError,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try library.importKey(text: text, name: nil, passphrase: passphrase), file: file, line: line) {
            XCTAssertEqual($0 as? ImportedKeyError, expected, file: file, line: line)
        }
        XCTAssertTrue(library.keys.isEmpty, "nothing stored", file: file, line: line)
        XCTAssertTrue((try? storage.list())?.isEmpty ?? false, "nothing stored", file: file, line: line)
    }

    func testUnencryptedEd25519ImportsWithTheCommentAsName() async throws {
        let info = try library.importKey(text: KeyFixtures.plainEd25519, name: nil, passphrase: nil)
        XCTAssertEqual(info.name, "cory@laptop")
        XCTAssertEqual(info.type, .ed25519)
        XCTAssertEqual(info.fingerprint, KeyFixtures.plainEd25519Fingerprint)
        XCTAssertEqual(SSHKeyCandidate.keyIdentity(info.publicKey), SSHKeyCandidate.keyIdentity(KeyFixtures.plainEd25519Public))
        XCTAssertEqual(info.importedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(library.keys, [info])
        XCTAssertEqual(try storage.list(), [info])

        // The stored copy is an unencrypted OpenSSH key of the same key.
        let stored = try storage.privateKey(id: info.id)
        let inspected = try SSHKeyImporter.inspect(privateKey: stored)
        XCTAssertFalse(inspected.isEncrypted)
        XCTAssertEqual(inspected.publicKey, KeyFixtures.plainEd25519Public)
    }

    func testAGivenNameWinsOverTheComment() async throws {
        let info = try library.importKey(text: KeyFixtures.plainEd25519, name: "  Work laptop ", passphrase: nil)
        XCTAssertEqual(info.name, "Work laptop")
    }

    func testEncryptedOpenSSHKeyImportsWithItsPassphrase() async throws {
        assertImportFails(KeyFixtures.encryptedEd25519, .needsPassphrase)
        assertImportFails(KeyFixtures.encryptedEd25519, passphrase: "", .needsPassphrase)
        assertImportFails(KeyFixtures.encryptedEd25519, passphrase: "wrong horse", .wrongPassphrase)

        let info = try library.importKey(text: KeyFixtures.encryptedEd25519, name: nil,
                                         passphrase: KeyFixtures.encryptedEd25519Passphrase)
        XCTAssertEqual(info.fingerprint, KeyFixtures.encryptedEd25519Fingerprint)
        XCTAssertFalse(info.name.isEmpty)
        let stored = try storage.privateKey(id: info.id)
        let inspected = try SSHKeyImporter.inspect(privateKey: stored)
        XCTAssertFalse(inspected.isEncrypted, "stored unencrypted: the Keychain item is the protection")
        XCTAssertEqual(inspected.publicKey.map(SSHKeyCandidate.keyIdentity),
                       SSHKeyCandidate.keyIdentity(KeyFixtures.encryptedEd25519Public))
        XCTAssertFalse(stored.contains(KeyFixtures.encryptedEd25519Passphrase))
    }

    func testPKCS8Ed25519Imports() async throws {
        let info = try library.importKey(text: KeyFixtures.pkcs8Ed25519, name: nil, passphrase: nil)
        XCTAssertEqual(info.fingerprint, KeyFixtures.pkcs8Ed25519Fingerprint)
        XCTAssertEqual(info.publicKey, KeyFixtures.pkcs8Ed25519Public)
        XCTAssertEqual(info.name, "Ed25519 key")
    }

    func testRejectedKeys() async throws {
        assertImportFails(KeyFixtures.rsa, .rsaNotSupported)
        assertImportFails(KeyFixtures.ecdsa, .unsupportedKeyType("ecdsa-sha2-nistp256"))
        assertImportFails("hello", .notAPrivateKey)
        assertImportFails(KeyFixtures.plainEd25519Public, .notAPrivateKey)
        assertImportFails(KeyFixtures.gcmEncryptedEd25519, passphrase: "pw", .unsupportedEncryption)
    }

    func testDuplicatePublicKeyIsRefused() async throws {
        _ = try library.importKey(text: KeyFixtures.plainEd25519, name: "First", passphrase: nil)
        XCTAssertThrowsError(try library.importKey(text: KeyFixtures.plainEd25519, name: "Again", passphrase: nil)) {
            XCTAssertEqual($0 as? ImportedKeyError, .duplicate(existingName: "First"))
        }
        XCTAssertEqual(library.keys.count, 1)
    }

    func testCandidatesReturnEveryKeyWithItsPublicKey() async throws {
        let a = try library.importKey(text: KeyFixtures.plainEd25519, name: "A", passphrase: nil)
        let b = try library.importKey(text: KeyFixtures.pkcs8Ed25519, name: "B", passphrase: nil)
        let candidates = try library.candidates()
        XCTAssertEqual(candidates.map(\.label), ["A", "B"])
        XCTAssertEqual(candidates.map(\.publicKey), [a.publicKey, b.publicKey])
        XCTAssertEqual(candidates.map(\.type), [.ed25519, .ed25519])
        XCTAssertEqual(candidates[0].pem, try storage.privateKey(id: a.id))
        // The stored keys are readable by the built-in engine's planner path.
        XCTAssertTrue(candidates.allSatisfy { $0.pem.contains("OPENSSH PRIVATE KEY") })
    }

    func testDeleteRemovesTheKeyAndItsSecret() async throws {
        let info = try library.importKey(text: KeyFixtures.plainEd25519, name: nil, passphrase: nil)
        try library.delete(info.id)
        XCTAssertTrue(library.keys.isEmpty)
        XCTAssertTrue(try storage.list().isEmpty)
        XCTAssertThrowsError(try storage.privateKey(id: info.id))
    }

    func testANewLibraryListsTheStoredKeys() async throws {
        let info = try library.importKey(text: KeyFixtures.plainEd25519, name: nil, passphrase: nil)
        XCTAssertEqual(ImportedKeyLibrary(storage: storage).keys, [info])
    }

    func testHostsUsingAKeyAreThoseThatPinIt() async throws {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        let info = try library.importKey(text: KeyFixtures.plainEd25519, name: nil, passphrase: nil)
        let pinned = AgentKeyChoice(publicKey: KeyFixtures.plainEd25519Public)
        let direct = vault.saveNow(SavedHost(label: "B direct", address: "b", username: "root", agentKey: pinned))
        let identity = vault.saveNow(Identity(label: "i", username: "u", agentKey: pinned))
        let viaIdentity = vault.saveNow(SavedHost(label: "A identity", address: "a", identityID: identity.id))
        _ = vault.saveNow(SavedHost(label: "Unpinned", address: "c", username: "root", agentKey: AgentKeyChoice(publicKey: nil)))
        _ = vault.saveNow(SavedHost(label: "Other", address: "d", username: "root",
                                    agentKey: AgentKeyChoice(publicKey: KeyFixtures.pkcs8Ed25519Public)))
        XCTAssertEqual(library.hosts(using: info, vault: vault).map(\.id), [viaIdentity.id, direct.id])
    }

    func testDescriptionsCarryNoKeyMaterial() async throws {
        let info = try library.importKey(text: KeyFixtures.plainEd25519, name: nil, passphrase: nil)
        let stored = try storage.privateKey(id: info.id)
        let body = stored.split(separator: "\n")[1]
        for text in ["\(info)", String(reflecting: info), "\(try library.candidates())"] {
            XCTAssertFalse(text.contains(body), text)
        }
        for error in [ImportedKeyError.needsPassphrase, .wrongPassphrase, .rsaNotSupported, .notAPrivateKey,
                      .duplicate(existingName: "x"), .unsupportedKeyType("ecdsa"), .unsupportedEncryption] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }
}
