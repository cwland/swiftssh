import XCTest
import Crypto
import CoreModels
@testable import SyncCore

final class VaultCryptoTests: XCTestCase {
    private let iterations = 1_000

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000.123)

    private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private func seal(_ plain: Data, id: UUID, type: SyncRecordType = .host, updatedAt: Date? = nil,
                      deleted: Bool = false, deviceID: String = "mac-a", key: SymmetricKey) throws -> Data {
        try VaultCrypto.seal(plain, id: id, type: type, updatedAt: updatedAt ?? stamp, deleted: deleted,
                             deviceID: deviceID, key: key)
    }

    private func open(_ sealed: Data, id: UUID, type: SyncRecordType = .host, updatedAt: Date? = nil,
                      deleted: Bool = false, deviceID: String = "mac-a", key: SymmetricKey) throws -> Data {
        try VaultCrypto.open(sealed, id: id, type: type, updatedAt: updatedAt ?? stamp, deleted: deleted,
                             deviceID: deviceID, key: key)
    }

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
        let sealed = try seal(plain, id: id, key: key)
        XCTAssertEqual(try open(sealed, id: id, key: key), plain)
    }

    func testOpenFailsWhenIdOrTypeDiffers() throws {
        let key = VaultCrypto.newVaultKey()
        let id1 = UUID(), id2 = UUID()
        let sealed = try seal(Data("x".utf8), id: id1, key: key)
        XCTAssertThrowsError(try open(sealed, id: id2, key: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
        }
        XCTAssertThrowsError(try open(sealed, id: id1, type: .snippet, key: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
        }
    }

    func testSealingTwiceGivesDifferentCiphertext() throws {
        let key = VaultCrypto.newVaultKey()
        let id = UUID()
        let p = Data("same".utf8)
        let a = try seal(p, id: id, key: key)
        let b = try seal(p, id: id, key: key)
        XCTAssertNotEqual(a, b)
    }

    func testCiphertextDoesNotContainPlaintext() throws {
        let key = VaultCrypto.newVaultKey()
        let sealed = try seal(Data("192.168.50.200".utf8), id: UUID(), key: key)
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
        var sealed = try seal(Data("secret".utf8), id: id, key: key)
        sealed[sealed.startIndex + 15] ^= 0x01
        XCTAssertThrowsError(try open(sealed, id: id, key: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
        }
    }

    func testOpenFailsWithWrongKey() throws {
        let id = UUID()
        let sealed = try seal(Data("secret".utf8), id: id, key: VaultCrypto.newVaultKey())
        XCTAssertThrowsError(try open(sealed, id: id, key: VaultCrypto.newVaultKey())) {
            XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
        }
    }

    func testOpenFailsWhenUpdatedAtDeletedOrDeviceIDDiffers() throws {
        let key = VaultCrypto.newVaultKey()
        let id = UUID()
        let sealed = try seal(Data("x".utf8), id: id, key: key)
        XCTAssertEqual(try open(sealed, id: id, key: key), Data("x".utf8))
        let tampered: [() throws -> Data] = [
            { try self.open(sealed, id: id, updatedAt: self.stamp.addingTimeInterval(0.001), key: key) },
            { try self.open(sealed, id: id, deleted: true, key: key) },
            { try self.open(sealed, id: id, deviceID: "mac-b", key: key) },
        ]
        for attempt in tampered {
            XCTAssertThrowsError(try attempt()) {
                XCTAssertEqual($0 as? VaultCryptoError, .tamperedRecord)
            }
        }
    }

    func testSubMillisecondDifferenceInUpdatedAtStillOpens() throws {
        // The AAD uses whole milliseconds (floored), the precision the server stores.
        let key = VaultCrypto.newVaultKey()
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000.123)
        let sealed = try seal(Data("x".utf8), id: id, updatedAt: base.addingTimeInterval(0.0004), key: key)
        XCTAssertEqual(try open(sealed, id: id, updatedAt: base, key: key), Data("x".utf8))
    }

    func testVaultKeyEqualityIsByKeyBytes() {
        let raw = VaultCrypto.newVaultKey()
        let a = VaultKey(raw)
        let b = VaultKey(SymmetricKey(data: bytes(raw)))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, VaultKey(VaultCrypto.newVaultKey()))
        XCTAssertEqual(bytes(a.symmetricKey), bytes(raw))
    }
}
