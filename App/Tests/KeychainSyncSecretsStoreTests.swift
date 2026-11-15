import XCTest
import Foundation
import Security
import AppCore
import SyncCore
@testable import TermiusReimagined

/// Uses the real login keychain with a unique service per test so the app's own sync secrets are
/// never touched; items are deleted in `tearDown`.
final class KeychainSyncSecretsStoreTests: XCTestCase {
    private var service = ""

    override func setUp() {
        super.setUp()
        service = "com.cwland.TermiusReimagined.sync.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        super.tearDown()
    }

    private func makeStore() -> KeychainSyncSecretsStore {
        KeychainSyncSecretsStore(service: service)
    }

    private func attributes(account: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    private func randomKey() throws -> VaultKey {
        try VaultKey(rawBytes: Data((0..<VaultKey.rawByteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    func testEmptyStoreLoadsNil() throws {
        XCTAssertNil(try makeStore().loadVaultKey())
        XCTAssertNil(try makeStore().loadAPIKey())
    }

    func testSavesAndLoadsVaultKey() throws {
        let key = try randomKey()
        try makeStore().saveVaultKey(key)

        XCTAssertEqual(try makeStore().loadVaultKey(), key)
    }

    func testSavingAgainReplacesVaultKey() throws {
        try makeStore().saveVaultKey(try randomKey())
        let second = try randomKey()
        try makeStore().saveVaultKey(second)

        XCTAssertEqual(try makeStore().loadVaultKey(), second)
    }

    func testSavesAndReplacesAPIKey() throws {
        try makeStore().saveAPIKey("first-key")
        try makeStore().saveAPIKey("second-key")

        XCTAssertEqual(try makeStore().loadAPIKey(), "second-key")
    }

    func testItemsAreStoredUnderExpectedAccountsAndNotSynchronizable() throws {
        try makeStore().saveVaultKey(try randomKey())
        try makeStore().saveAPIKey("key")

        // Behaviour, not kSecAttrAccessible: the file-based keychain may not return it.
        for account in ["vaultKey", "apiKey"] {
            let found = try XCTUnwrap(attributes(account: account), account)
            // Absent or false both mean "not synchronizable" (never iCloud Keychain).
            let synchronizable = found[kSecAttrSynchronizable as String] as? Bool
            XCTAssertNotEqual(synchronizable, true, account)
        }
        XCTAssertEqual(try makeStore().loadAPIKey(), "key")
    }

    func testDeleteAllRemovesBothAndToleratesMissingItems() throws {
        try makeStore().deleteAll()
        try makeStore().saveVaultKey(try randomKey())
        try makeStore().saveAPIKey("key")

        try makeStore().deleteAll()

        XCTAssertNil(try makeStore().loadVaultKey())
        XCTAssertNil(try makeStore().loadAPIKey())
    }
}
