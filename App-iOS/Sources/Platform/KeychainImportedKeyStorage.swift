import Foundation
import LocalAuthentication
import Security
import AppCore

/// Imported SSH keys in the iOS Keychain, on this device only: never synchronizable, never in
/// iCloud Keychain or a backup restored on another device, readable only while the device is
/// unlocked. Each private key is its own item and needs Face ID / Touch ID / the passcode to be
/// read (`.userPresence`); the list of keys (names, public keys, fingerprints; no secrets) is one
/// more item without that check, so listing never prompts.
///
/// One successful check covers reading keys for `reuseDuration`: call `authorize(reason:)` before a
/// connection. Reads never prompt: without a recent check they fail with `errSecInteractionNotAllowed`
/// (`isLockedError`), so nothing blocks the main thread behind the system sheet.
final class KeychainImportedKeyStorage: ImportedKeyStorage, @unchecked Sendable {
    static let defaultService = "com.cwland.SwiftSSH.mobile.importedKeys"
    static let indexAccount = "index"
    /// How long one Face ID / passcode check covers reading keys.
    static let reuseDuration: TimeInterval = 60

    let service: String
    /// Guards `context` and `authorizedAt`.
    private let lock = NSLock()
    private var context = KeychainImportedKeyStorage.nonInteractiveContext()
    private var authorizedAt: Date?

    init(service: String = KeychainImportedKeyStorage.defaultService) {
        self.service = service
    }

    // MARK: ImportedKeyStorage

    func list() throws -> [ImportedKeyInfo] {
        guard let data = try read(account: Self.indexAccount, context: nil) else { return [] }
        do {
            return try JSONDecoder().decode([ImportedKeyInfo].self, from: data)
        } catch {
            throw KeychainError.unexpectedItemData
        }
    }

    func save(_ info: ImportedKeyInfo, privateKey: String) throws {
        try deleteItem(account: info.id.uuidString)
        try addProtectedItem(Data(privateKey.utf8), account: info.id.uuidString, label: "SwiftSSH imported key: \(info.name)")
        var index = try list()
        index.removeAll { $0.id == info.id }
        index.append(info)
        do {
            try writeIndex(index)
        } catch {
            // Don't leave a key that no list shows.
            try? deleteItem(account: info.id.uuidString)
            throw error
        }
    }

    func privateKey(id: UUID) throws -> String {
        guard let data = try read(account: id.uuidString, context: currentContext()) else {
            throw KeychainError.status(errSecItemNotFound)
        }
        guard let key = String(data: data, encoding: .utf8) else { throw KeychainError.unexpectedItemData }
        return key
    }

    func delete(id: UUID) throws {
        try deleteItem(account: id.uuidString)
        var index = try list()
        index.removeAll { $0.id == id }
        try writeIndex(index)
    }

    // MARK: Authorization

    /// Asks for Face ID / Touch ID / the passcode once, so the key reads of the next `reuseDuration`
    /// don't. Returns false when the user cancelled or the check failed. Call it before a connection
    /// that reads keys: the reads themselves never show a prompt (they fail instead), so planning on
    /// the main actor can't block behind the system sheet.
    func authorize(reason: String) async -> Bool {
        if lock.withLock({ authorizedAt.map { Date().timeIntervalSince($0) < Self.reuseDuration } ?? false }) {
            return true
        }
        let fresh = LAContext()
        fresh.localizedReason = reason
        do {
            guard try await fresh.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return false }
        } catch {
            return false
        }
        fresh.interactionNotAllowed = true
        lock.withLock {
            context.invalidate()
            context = fresh
            authorizedAt = Date()
        }
        return true
    }

    /// Whether a check is recent enough that reading keys won't fail for want of one.
    var isAuthorized: Bool {
        lock.withLock { authorizedAt.map { Date().timeIntervalSince($0) < Self.reuseDuration } ?? false }
    }

    /// The shared context (never interactive); a new, unauthorized one once the last check is older
    /// than `reuseDuration`.
    private func currentContext() -> LAContext {
        lock.withLock {
            if let authorizedAt, Date().timeIntervalSince(authorizedAt) >= Self.reuseDuration {
                context.invalidate()
                context = Self.nonInteractiveContext()
                self.authorizedAt = nil
            }
            return context
        }
    }

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    // MARK: Keychain

    private func writeIndex(_ index: [ImportedKeyInfo]) throws {
        let data = try JSONEncoder().encode(index)
        let query = baseQuery(account: Self.indexAccount)
        let changes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes[kSecAttrLabel as String] = "SwiftSSH imported keys list"
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        default:
            throw KeychainError.status(status)
        }
    }

    private func addProtectedItem(_ data: Data, account: String, label: String) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .userPresence, &error) else {
            error?.release()
            throw KeychainError.status(errSecParam)
        }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessControl as String] = access
        attributes[kSecAttrLabel as String] = label
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// The item's data, or nil when it doesn't exist.
    private func read(account: String, context: LAContext?) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedItemData }
            if context != nil { lock.withLock { authorizedAt = authorizedAt ?? Date() } }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Whether a failed read only means no recent Face ID / passcode check (or it was cancelled).
    static func isLockedError(_ error: any Error) -> Bool {
        guard case KeychainError.status(let status) = error else { return false }
        return status == errSecInteractionNotAllowed || status == errSecUserCanceled || status == errSecAuthFailed
    }

    private func deleteItem(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
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
