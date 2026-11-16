import Foundation
import Security
import AppCore
import SyncCore

/// Keeps this Mac's sync secrets (the vault key and the server's API key) as generic passwords in
/// the login keychain, readable after the first unlock, on this device only (never synchronized
/// through iCloud Keychain). Errors carry only an `OSStatus`, never the secret.
struct KeychainSyncSecretsStore: SyncSecretsStore {
    static let defaultService = "com.cwland.SwiftSSH.sync"
    static let vaultKeyAccount = "vaultKey"
    static let apiKeyAccount = "apiKey"

    let service: String

    init(service: String = KeychainSyncSecretsStore.defaultService) {
        self.service = service
    }

    func loadVaultKey() throws -> VaultKey? {
        guard let data = try read(account: Self.vaultKeyAccount) else { return nil }
        return try VaultKey(rawBytes: data)
    }

    func saveVaultKey(_ key: VaultKey) throws {
        try write(key.rawBytes, account: Self.vaultKeyAccount, label: "SwiftSSH sync vault key")
    }

    func loadAPIKey() throws -> String? {
        guard let data = try read(account: Self.apiKeyAccount) else { return nil }
        guard let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedItemData
        }
        return key
    }

    func saveAPIKey(_ key: String) throws {
        try write(Data(key.utf8), account: Self.apiKeyAccount, label: "SwiftSSH sync API key")
    }

    /// Removes both items; items that don't exist are not an error.
    func deleteAll() throws {
        for account in [Self.vaultKeyAccount, Self.apiKeyAccount] {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.status(status)
            }
        }
    }

    // MARK: Keychain

    /// The item's data, or nil when it does not exist.
    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedItemData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Updates the item if it exists, otherwise adds it.
    private func write(_ data: Data, account: String, label: String) throws {
        let query = baseQuery(account: account)
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrLabel as String] = label
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // Created by another caller between the update and the add: update theirs.
                let retryStatus = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
                guard retryStatus == errSecSuccess else { throw KeychainError.status(retryStatus) }
                return
            }
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        default:
            throw KeychainError.status(updateStatus)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }
}
