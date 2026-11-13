import Foundation
import Crypto
import _CryptoExtras
import CoreModels

public enum VaultCryptoError: Error, Equatable {
    case wrongPassphrase
    case tamperedRecord
}

/// The vault's random 256-bit key, as `SyncEngine` hands it out and takes it back (the app keeps
/// it, e.g. in the Keychain). `@unchecked Sendable`: it only wraps an immutable `SymmetricKey`,
/// which swift-crypto (unlike CryptoKit) doesn't declare `Sendable`.
public struct VaultKey: @unchecked Sendable, Equatable {
    public let symmetricKey: SymmetricKey

    public init(_ symmetricKey: SymmetricKey) {
        self.symmetricKey = symmetricKey
    }

    /// Equal when the raw key bytes are equal.
    public static func == (lhs: VaultKey, rhs: VaultKey) -> Bool {
        lhs.symmetricKey.withUnsafeBytes { l in
            rhs.symmetricKey.withUnsafeBytes { r in l.elementsEqual(r) }
        }
    }
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
            from: Data(passphrase.precomposedStringWithCanonicalMapping.utf8),
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

    /// Seals a record's JSON. The AAD binds the ciphertext to the record's id, type and the
    /// metadata the server stores in the clear (`updatedAt` in whole milliseconds, `deleted`,
    /// `deviceID`), so the server can't swap, resurrect, delete or re-date a record unnoticed.
    public static func seal(_ plaintext: Data, id: UUID, type: SyncRecordType, updatedAt: Date,
                            deleted: Bool, deviceID: String, key: SymmetricKey) throws -> Data {
        let aad = aad(id: id, type: type, updatedAt: updatedAt, deleted: deleted, deviceID: deviceID)
        return try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined!
    }

    /// Opens a record sealed by `seal`; throws `.tamperedRecord` if the ciphertext or any of the
    /// authenticated metadata differs.
    public static func open(_ ciphertext: Data, id: UUID, type: SyncRecordType, updatedAt: Date,
                            deleted: Bool, deviceID: String, key: SymmetricKey) throws -> Data {
        let aad = aad(id: id, type: type, updatedAt: updatedAt, deleted: deleted, deviceID: deviceID)
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch is CryptoKitError {
            throw VaultCryptoError.tamperedRecord
        }
    }

    /// `"<id>|<type>|<updatedAt ms, floored>|<1 if deleted else 0>|<deviceID>"` as UTF-8.
    static func aad(id: UUID, type: SyncRecordType, updatedAt: Date, deleted: Bool, deviceID: String) -> Data {
        let updatedAtMs = Int64((updatedAt.timeIntervalSince1970 * 1000).rounded(.down))
        return Data("\(id.uuidString)|\(type.rawValue)|\(updatedAtMs)|\(deleted ? 1 : 0)|\(deviceID)".utf8)
    }
}
