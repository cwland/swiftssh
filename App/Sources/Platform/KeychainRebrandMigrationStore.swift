import Foundation
import Security
import AppCore

/// The Keychain side of the one-time move from Termius Reimagined to SwiftSSH (`RebrandMigration`):
/// generic passwords in the login keychain, never synchronized, with the same attributes
/// `KeychainVaultKeyProvider` and `KeychainSyncSecretsStore` use. Errors carry only an `OSStatus`,
/// never an item's data.
struct KeychainRebrandMigrationStore: RebrandMigrationKeychain {
    func readData(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedItemData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Attributes only: no access prompt.
    func contains(service: String, account: String) throws -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError.status(status)
        }
    }

    /// Attributes only: no access prompt.
    func accounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.status(status)
        }
    }

    func add(_ data: Data, service: String, account: String, kind: RebrandMigrationKeychainItemKind) throws {
        var attributes = baseQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        switch kind {
        case .vaultKey:
            // As `KeychainVaultKeyProvider` creates it.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributes[kSecAttrLabel as String] = "SwiftSSH vault key"
        case .syncSecret:
            // As `KeychainSyncSecretsStore` writes it.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrLabel as String] = Self.syncLabel(account: account)
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private static func syncLabel(account: String) -> String {
        switch account {
        case KeychainSyncSecretsStore.vaultKeyAccount: "SwiftSSH sync vault key"
        case KeychainSyncSecretsStore.apiKeyAccount: "SwiftSSH sync API key"
        default: "SwiftSSH sync \(account)"
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }
}
