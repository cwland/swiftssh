import XCTest
import Crypto
import CoreModels
@testable import SyncCore

final class VaultCryptoTests: XCTestCase {
    private let iterations = 1_000

    private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    func testWrapUnwrapRoundTrip() throws {
        let salt = VaultCrypto.randomSalt()
        let pk = try VaultCrypto.deriveKey(passphrase: "correct horse", salt: salt, iterations: iterations)
        let k = VaultCrypto.newVaultKey()
        let wrapped = try VaultCrypto.wrap(vaultKey: k, with: pk)
        let unwrapped = try VaultCrypto.unwrap(wrapped, with: pk)
        XCTAssertEqual(bytes(unwrapped), bytes(k))
        XCTAssertEqual(bytes(k).count, 32)
        XCTAssertEqual(salt.count, 16)
    }

    func testWrongPassphraseThrows() throws {
        let salt = VaultCrypto.randomSalt()
        let pk = try VaultCrypto.deriveKey(passphrase: "correct horse", salt: salt, iterations: iterations)
        let wrapped = try VaultCrypto.wrap(vaultKey: VaultCrypto.newVaultKey(), with: pk)
        let wrong = try VaultCrypto.deriveKey(passphrase: "wrong", salt: salt, iterations: iterations)
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, with: wrong)) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongPassphrase)
        }
        XCTAssertThrowsError(try VaultCrypto.unwrap(Data([1, 2, 3]), with: pk)) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongPassphrase)
        }
    }

    func testSameInputsDeriveSameKey() throws {
        let salt = VaultCrypto.randomSalt()
        let a = try VaultCrypto.deriveKey(passphrase: "pw", salt: salt, iterations: iterations)
        let b = try VaultCrypto.deriveKey(passphrase: "pw", salt: salt, iterations: iterations)
        let c = try VaultCrypto.deriveKey(passphrase: "pw2", salt: salt, iterations: iterations)
        XCTAssertEqual(bytes(a), bytes(b))
        XCTAssertNotEqual(bytes(a), bytes(c))
        XCTAssertEqual(bytes(a).count, 32)
    }

    func testSealOpenRoundTrip() throws {
        let key = VaultCrypto.newVaultKey()
        let id = UUID()
        let plain = Data("hello".utf8)
        let sealed = try VaultCrypto.seal(plain, id: id, type: .host, key: key)
        XCTAssertEqual(try VaultCrypto.open(sealed, id: id, type: .host, key: key), plain)
    }

    func testOpenFailsWhenIdOrTypeDiffers() throws {
        let key = VaultCrypto.newVaultKey()
        let id1 = UUID(), id2 = UUID()
        let sealed = try VaultCrypto.seal(Data("x".utf8), id: id1, type: .host, key: key)
        XCTAssertThrowsError(try VaultCrypto.open(sealed, id: id2, type: .host, key: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
        }
        XCTAssertThrowsError(try VaultCrypto.open(sealed, id: id1, type: .snippet, key: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
        }
    }

    func testSealingTwiceGivesDifferentCiphertext() throws {
        let key = VaultCrypto.newVaultKey()
        let id = UUID()
        let p = Data("same".utf8)
        let a = try VaultCrypto.seal(p, id: id, type: .host, key: key)
        let b = try VaultCrypto.seal(p, id: id, type: .host, key: key)
        XCTAssertNotEqual(a, b)
    }

    func testCiphertextDoesNotContainPlaintext() throws {
        let key = VaultCrypto.newVaultKey()
        let sealed = try VaultCrypto.seal(Data("192.168.50.200".utf8), id: UUID(), type: .host, key: key)
        XCTAssertNil(sealed.range(of: Data("192.168".utf8)))
    }

    func testComposedAndDecomposedPassphraseDeriveSameKey() throws {
        let salt = VaultCrypto.randomSalt()
        let a = try VaultCrypto.deriveKey(passphrase: "caf\u{E9}", salt: salt, iterations: iterations)
        let b = try VaultCrypto.deriveKey(passphrase: "cafe\u{301}", salt: salt, iterations: iterations)
        XCTAssertEqual(bytes(a), bytes(b))
    }

    func testOpenFailsWhenCiphertextIsModified() throws {
        let key = VaultCrypto.newVaultKey()
        let id = UUID()
        var sealed = try VaultCrypto.seal(Data("secret".utf8), id: id, type: .host, key: key)
        sealed[sealed.startIndex + 15] ^= 0x01
        XCTAssertThrowsError(try VaultCrypto.open(sealed, id: id, type: .host, key: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
        }
    }

    func testOpenFailsWithWrongKey() throws {
        let id = UUID()
        let sealed = try VaultCrypto.seal(Data("secret".utf8), id: id, type: .host, key: VaultCrypto.newVaultKey())
        XCTAssertThrowsError(try VaultCrypto.open(sealed, id: id, type: .host, key: VaultCrypto.newVaultKey())) {
            XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
        }
    }
}
