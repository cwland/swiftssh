import Foundation
import Security
import AppCore
import SyncCore

enum KeychainError: Error, Equatable {
    /// A Security framework call returned this status.
    case status(OSStatus)
    /// The Keychain returned an item whose data was not `Data`.
    case unexpectedItemData
}

/// Keeps the local vault's 32-byte key as a generic password in the login keychain
/// (not synchronizable). Reads first; creates a random key only when the item does not exist.
/// Any other failure throws, so an existing vault is never orphaned by a fresh key.
struct KeychainVaultKeyProvider: VaultKeyProvider {
    let service: String
    let account: String

    init(service: String = "com.cwland.TermiusReimagined", account: String = "local-vault-key") {
        self.service = service
        self.account = account
    }

    func loadOrCreateKey() throws -> VaultKey {
        if let existing = try readKey() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: VaultKey.rawByteCount)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw KeychainError.status(randomStatus)
        }
        let data = Data(bytes)

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "Termius Reimagined vault key"

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return try VaultKey(rawBytes: data)
        case errSecDuplicateItem:
            // Another caller created the item between our read and add: use theirs.
            guard let existing = try readKey() else {
                throw KeychainError.status(errSecDuplicateItem)
            }
            return existing
        default:
            throw KeychainError.status(addStatus)
        }
    }

    /// The stored key, or nil when the item does not exist.
    private func readKey() throws -> VaultKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedItemData
            }
            return try VaultKey(rawBytes: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }
}
