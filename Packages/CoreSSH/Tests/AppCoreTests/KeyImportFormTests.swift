import XCTest
import CoreModels
import SSHCore
@testable import AppCore

/// The Keys screen's import form on iPhone/iPad: paste or file, passphrase asked only when needed.
@MainActor
final class KeyImportFormTests: XCTestCase {
    private var storage: InMemoryImportedKeyStorage!
    private var library: ImportedKeyLibrary!
    private var form: KeyImportForm!

    override func setUp() async throws {
        storage = InMemoryImportedKeyStorage()
        library = ImportedKeyLibrary(storage: storage)
        form = KeyImportForm(library: library)
    }

    func testPlainKeyImportsAndTheFormClears() async throws {
        XCTAssertFalse(form.canImport)
        form.text = KeyFixtures.plainEd25519
        form.name = "  "
        XCTAssertTrue(form.canImport)
        let info = try XCTUnwrap(form.submit())
        XCTAssertEqual(info.name, "cory@laptop")
        XCTAssertEqual(library.keys, [info])
        XCTAssertEqual(form.text, "")
        XCTAssertEqual(form.name, "")
        XCTAssertNil(form.errorMessage)
        XCTAssertFalse(form.needsPassphrase)
    }

    func testEncryptedKeyAsksForThePassphraseThenImports() async throws {
        form.text = KeyFixtures.encryptedEd25519
        XCTAssertNil(form.submit())
        XCTAssertTrue(form.needsPassphrase)
        XCTAssertFalse(form.canImport, "needs the passphrase now")
        XCTAssertTrue(library.keys.isEmpty)

        form.passphrase = "wrong horse"
        XCTAssertNil(form.submit())
        XCTAssertEqual(form.errorMessage, ImportedKeyError.wrongPassphrase.errorDescription)
        XCTAssertEqual(form.passphrase, "", "a wrong passphrase is cleared")
        XCTAssertTrue(library.keys.isEmpty)

        form.passphrase = KeyFixtures.encryptedEd25519Passphrase
        form.name = "Mac key"
        let info = try XCTUnwrap(form.submit())
        XCTAssertEqual(info.name, "Mac key")
        XCTAssertEqual(form.passphrase, "", "the passphrase never stays in the form")
        XCTAssertFalse(form.needsPassphrase)
    }

    func testChangingTheTextStartsOverWithoutThePassphrase() async {
        form.text = KeyFixtures.encryptedEd25519
        _ = form.submit()
        form.passphrase = "something"
        form.text = KeyFixtures.plainEd25519
        XCTAssertFalse(form.needsPassphrase)
        XCTAssertEqual(form.passphrase, "")
        XCTAssertNil(form.errorMessage)
    }

    func testErrorsAreShownAndNothingIsStored() async throws {
        form.text = "ssh-ed25519 AAAA public only"
        XCTAssertNil(form.submit())
        XCTAssertEqual(form.errorMessage, ImportedKeyError.notAPrivateKey.errorDescription)
        form.text = KeyFixtures.plainEd25519
        XCTAssertNotNil(form.submit())
        form.text = KeyFixtures.plainEd25519
        XCTAssertNil(form.submit())
        XCTAssertEqual(form.errorMessage, ImportedKeyError.duplicate(existingName: "cory@laptop").errorDescription)
        XCTAssertEqual(library.keys.count, 1)
    }

    func testLoadingAFileFillsTheTextAndSuggestsItsName() async throws {
        XCTAssertTrue(form.load(fileData: Data(KeyFixtures.plainEd25519.utf8), fileName: "work-laptop.key"))
        XCTAssertEqual(form.text, KeyFixtures.plainEd25519)
        XCTAssertEqual(form.name, "work-laptop")
        form.name = "Mine"
        XCTAssertTrue(form.load(fileData: Data(KeyFixtures.plainEd25519.utf8), fileName: "id_ed25519"))
        XCTAssertEqual(form.name, "Mine", "a name already typed stays")
    }

    func testLoadingABinaryFileSaysSo() async {
        XCTAssertFalse(form.load(fileData: Data([0xFF, 0xFE, 0x00, 0x80]), fileName: "x.bin"))
        XCTAssertEqual(form.errorMessage, KeyImportForm.notTextMessage)
        XCTAssertEqual(form.text, "")
    }

    func testLibraryDeleteAllRemovesEveryKey() async throws {
        try library.importKey(text: KeyFixtures.plainEd25519, name: nil, passphrase: nil)
        try library.importKey(text: KeyFixtures.encryptedEd25519, name: nil, passphrase: KeyFixtures.encryptedEd25519Passphrase)
        try library.deleteAll()
        XCTAssertTrue(library.keys.isEmpty)
        XCTAssertTrue(try storage.list().isEmpty)
    }
}
