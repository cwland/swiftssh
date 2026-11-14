import XCTest
import Foundation
import Security
import AppCore
import SyncCore
@testable import TermiusReimagined

/// Uses the real login keychain with a unique service per test so the app's own vault key is
/// never touched; items are deleted in `tearDown`.
final class KeychainVaultKeyProviderTests: XCTestCase {
    private let account = "test-vault-key"
    private var service = ""

    override func setUp() {
        super.setUp()
        service = "com.cwland.TermiusReimagined.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        super.tearDown()
    }

    private func makeProvider() -> KeychainVaultKeyProvider {
        KeychainVaultKeyProvider(service: service, account: account)
    }

    /// The stored item's data, or nil when there is none.
    private func storedData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func testCreatesKeyWhenMissing() throws {
        XCTAssertNil(storedData())

        let key = try makeProvider().loadOrCreateKey()

        XCTAssertEqual(storedData(), key.rawBytes)
    }

    func testReturnsSameKeyOnSecondCall() throws {
        let first = try makeProvider().loadOrCreateKey()
        let second = try makeProvider().loadOrCreateKey()

        XCTAssertEqual(first, second)
    }

    func testKeyIsThirtyTwoBytes() throws {
        let key = try makeProvider().loadOrCreateKey()

        XCTAssertEqual(key.rawBytes.count, 32)
    }

    func testWrongLengthItemThrowsAndIsNotReplaced() throws {
        let badData = Data(repeating: 0x5A, count: 16)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: badData,
        ]
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)

        XCTAssertThrowsError(try makeProvider().loadOrCreateKey()) { error in
            XCTAssertEqual(error as? VaultKeyBytesError, .wrongLength(16))
        }
        XCTAssertEqual(storedData(), badData)
    }

    func testReportsCreationOnlyOnFirstCall() throws {
        let first = try makeProvider().loadOrCreateKeyReportingCreation()
        let second = try makeProvider().loadOrCreateKeyReportingCreation()

        XCTAssertTrue(first.created)
        XCTAssertFalse(second.created)
        XCTAssertEqual(first.key, second.key)
    }
}
