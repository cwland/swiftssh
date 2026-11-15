import Foundation
import SyncCore

/// Where this Mac keeps its sync secrets: the vault key (so the passphrase is asked once per Mac)
/// and the server's API key. The app implements it with the Keychain; tests use
/// `InMemorySyncSecretsStore`. Implementations never log the values.
public protocol SyncSecretsStore: Sendable {
    func loadVaultKey() throws -> VaultKey?
    func saveVaultKey(_ key: VaultKey) throws
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAll() throws
}

/// A `SyncSecretsStore` in memory, for tests and previews.
public final class InMemorySyncSecretsStore: SyncSecretsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var vaultKey: VaultKey?
    private var apiKey: String?

    public init() {}

    public func loadVaultKey() throws -> VaultKey? { lock.withLock { vaultKey } }
    public func saveVaultKey(_ key: VaultKey) throws { lock.withLock { vaultKey = key } }
    public func loadAPIKey() throws -> String? { lock.withLock { apiKey } }
    public func saveAPIKey(_ key: String) throws { lock.withLock { apiKey = key } }

    public func deleteAll() throws {
        lock.withLock {
            vaultKey = nil
            apiKey = nil
        }
    }
}
