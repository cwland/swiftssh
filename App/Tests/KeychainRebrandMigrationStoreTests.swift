import XCTest
import Foundation
import Security
import AppCore
import SyncCore
@testable import SwiftSSH

/// Uses the real login keychain with unique services per test (never the app's own items); items
/// are deleted in `tearDown`. Also runs the whole migration against those services and a temp folder.
final class KeychainRebrandMigrationStoreTests: XCTestCase {
    private var oldService = ""
    private var newService = ""
    private var oldSync = ""
    private var newSync = ""
    private var root: URL!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        oldService = "com.cwland.TermiusReimagined.tests.\(id)"
        newService = "com.cwland.SwiftSSH.tests.\(id)"
        oldSync = oldService + ".sync"
        newSync = newService + ".sync"
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rebrand-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for service in [oldService, newService, oldSync, newSync] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
        }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAddReadContainsAndAccounts() throws {
        let store = KeychainRebrandMigrationStore()
        XCTAssertNil(try store.readData(service: newSync, account: "apiKey"))
        XCTAssertFalse(try store.contains(service: newSync, account: "apiKey"))
        XCTAssertEqual(try store.accounts(service: newSync), [])

        try store.add(Data("a".utf8), service: newSync, account: "apiKey", kind: .syncSecret)
        try store.add(Data("b".utf8), service: newSync, account: "vaultKey", kind: .syncSecret)

        XCTAssertEqual(try store.readData(service: newSync, account: "apiKey"), Data("a".utf8))
        XCTAssertTrue(try store.contains(service: newSync, account: "vaultKey"))
        XCTAssertEqual(try store.accounts(service: newSync).sorted(), ["apiKey", "vaultKey"])
        XCTAssertThrowsError(try store.add(Data("c".utf8), service: newSync, account: "apiKey", kind: .syncSecret))
    }

    func testMigratedVaultKeyIsReadByTheVaultKeyProvider() throws {
        let key = Data((0..<VaultKey.rawByteCount).map { _ in UInt8.random(in: .min ... .max) })
        let store = KeychainRebrandMigrationStore()
        try store.add(key, service: oldService, account: "local-vault-key", kind: .vaultKey)
        try store.add(Data("api".utf8), service: oldSync, account: KeychainSyncSecretsStore.apiKeyAccount, kind: .syncSecret)
        let oldDir = root.appendingPathComponent("TermiusReimagined", isDirectory: true)
        let newDir = root.appendingPathComponent("SwiftSSH", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: oldDir.appendingPathComponent("vault.bin"))
        let suite = "com.cwland.SwiftSSH.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var names = RebrandMigration.Names.standard
        names.oldVaultKeyService = oldService
        names.newVaultKeyService = newService
        names.oldSyncService = oldSync
        names.newSyncService = newSync
        names.newDefaultsDomain = suite
        let report = try RebrandMigration(oldDirectory: oldDir, newDirectory: newDir, keychain: store,
                                          defaults: defaults, names: names).migrateVaultIfNeeded()

        XCTAssertEqual(report.vault, .migrated)
        let loaded = try KeychainVaultKeyProvider(service: newService).loadOrCreateKeyReportingCreation()
        XCTAssertFalse(loaded.created)
        XCTAssertEqual(loaded.key.rawBytes, key)
        XCTAssertEqual(try KeychainSyncSecretsStore(service: newSync).loadAPIKey(), "api")
        XCTAssertEqual(try Data(contentsOf: newDir.appendingPathComponent("vault.bin")), Data("vault".utf8))
    }
}
