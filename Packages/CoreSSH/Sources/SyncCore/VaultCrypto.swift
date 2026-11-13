import Foundation
import Crypto
import _CryptoExtras
import CoreModels

public enum VaultCryptoError: Error, Equatable {
    case wrongPassphrase
    case tamperedRecord
}

/// Client-side vault crypto. The sync server only ever sees output of `seal`/`wrap`.
public enum VaultCrypto {
    public static let defaultIterations = 600_000

    public static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    public static func newVaultKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        try KDF.Insecure.PBKDF2.deriveKey(
            from: Data(passphrase.utf8),
            salt: salt,
            using: .sha256,
            outputByteCount: 32,
            unsafeUncheckedRounds: iterations
        )
    }

    public static func wrap(vaultKey: SymmetricKey, with key: SymmetricKey) throws -> Data {
        let raw = vaultKey.withUnsafeBytes { Data($0) }
        // `combined` is non-nil when the default 12-byte nonce is used.
        return try AES.GCM.seal(raw, using: key).combined!
    }

    public static func unwrap(_ wrapped: Data, with key: SymmetricKey) throws -> SymmetricKey {
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            return SymmetricKey(data: try AES.GCM.open(box, using: key))
        } catch is CryptoKitError {
            throw VaultCryptoError.wrongPassphrase
        }
    }

    public static func seal(_ plaintext: Data, id: UUID, type: SyncRecordType, key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(plaintext, using: key, authenticating: aad(id: id, type: type)).combined!
    }

    public static func open(_ ciphertext: Data, id: UUID, type: SyncRecordType, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key, authenticating: aad(id: id, type: type))
        } catch is CryptoKitError {
            throw VaultCryptoError.tamperedRecord
        }
    }

    private static func aad(id: UUID, type: SyncRecordType) -> Data {
        Data("\(id.uuidString)|\(type.rawValue)".utf8)
    }
}
