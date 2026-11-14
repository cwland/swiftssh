import Foundation
import Crypto
import SyncCore

public enum VaultKeyBytesError: Error, Equatable, Sendable, LocalizedError {
    /// A vault key must be exactly 32 bytes (AES-256); the given data had this many.
    case wrongLength(Int)

    public var errorDescription: String? {
        switch self {
        case .wrongLength(let count):
            "The saved vault key is invalid: it is \(count) bytes long, but a vault key must be "
                + "\(VaultKey.rawByteCount) bytes."
        }
    }
}

/// Raw-byte conversion so platform key stores (the Mac app's Keychain) can store a `VaultKey`
/// without importing a crypto framework themselves.
extension VaultKey {
    public static let rawByteCount = 32

    public init(rawBytes: Data) throws {
        guard rawBytes.count == Self.rawByteCount else {
            throw VaultKeyBytesError.wrongLength(rawBytes.count)
        }
        self.init(SymmetricKey(data: rawBytes))
    }

    public var rawBytes: Data {
        symmetricKey.withUnsafeBytes { Data($0) }
    }
}
