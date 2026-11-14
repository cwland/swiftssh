import SyncCore

/// Supplies the vault's encryption key. The Mac app backs this with the Keychain; tests use
/// `StaticKeyProvider`.
public protocol VaultKeyProvider: Sendable {
    func loadOrCreateKey() throws -> VaultKey
}

public struct StaticKeyProvider: VaultKeyProvider {
    private let key: VaultKey

    public init(key: VaultKey) {
        self.key = key
    }

    public func loadOrCreateKey() throws -> VaultKey { key }
}
