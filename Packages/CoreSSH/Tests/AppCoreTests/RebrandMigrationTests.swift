import Foundation
import XCTest
@testable import AppCore

/// Records every Keychain and file operation in one shared log, so tests can check their order.
private final class OperationLog {
    var entries: [String] = []
}

private struct ItemKey: Hashable {
    let service: String
    let account: String
}

private struct FakeKeychainError: Error, LocalizedError {
    var errorDescription: String? { "Keychain error -128: User canceled the operation." }
}

private final class FakeKeychain: RebrandMigrationKeychain {
    var items: [ItemKey: Data] = [:]
    /// Reads of these items fail as a denied access prompt would.
    var deniedReads: Set<ItemKey> = []
    var failingAdds: Set<ItemKey> = []
    var failAccountListing = false
    var kinds: [ItemKey: RebrandMigrationKeychainItemKind] = [:]
    let log: OperationLog

    init(log: OperationLog) { self.log = log }

    func readData(service: String, account: String) throws -> Data? {
        let key = ItemKey(service: service, account: account)
        log.entries.append("keychain.read \(service) \(account)")
        if deniedReads.contains(key) { throw FakeKeychainError() }
        return items[key]
    }

    func contains(service: String, account: String) throws -> Bool {
        items[ItemKey(service: service, account: account)] != nil
    }

    func accounts(service: String) throws -> [String] {
        if failAccountListing { throw FakeKeychainError() }
        return items.keys.filter { $0.service == service }.map(\.account).sorted()
    }

    func add(_ data: Data, service: String, account: String, kind: RebrandMigrationKeychainItemKind) throws {
        let key = ItemKey(service: service, account: account)
        log.entries.append("keychain.add \(service) \(account)")
        if failingAdds.contains(key) { throw FakeKeychainError() }
        guard items[key] == nil else { throw FakeKeychainError() }
        items[key] = data
        kinds[key] = kind
    }
}

/// Wraps the real file system (a temp folder) and logs copies and renames.
private final class LoggingFileSystem: RebrandMigrationFileSystem {
    let real = FileManagerMigrationFileSystem()
    let log: OperationLog
    /// Copies whose source has this last path component fail.
    var failingCopies: Set<String> = []
    /// Renames whose destination has this last path component fail (as a crash would leave things).
    var failingMoves: Set<String> = []

    init(log: OperationLog) { self.log = log }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { real.isDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [String] { try real.contentsOfDirectory(at: url) }
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func removeItem(at url: URL) throws { try real.removeItem(at: url) }

    func copyItem(at source: URL, to destination: URL) throws {
        log.entries.append("fs.copy \(source.lastPathComponent)")
        if failingCopies.contains(source.lastPathComponent) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try real.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        log.entries.append("fs.move \(destination.lastPathComponent)")
        if failingMoves.contains(destination.lastPathComponent) {
            throw CocoaError(.fileWriteUnknown)
        }
        try real.moveItem(at: source, to: destination)
    }
}

private final class FakeDefaults: RebrandMigrationDefaults {
    var domains: [String: [String: Any]] = [:]
    let standardName: String

    init(standardName: String) { self.standardName = standardName }

    func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }

    func set(_ value: Any?, forKey defaultName: String) {
        domains[standardName, default: [:]][defaultName] = value
    }

    func bool(forKey defaultName: String) -> Bool {
        domains[standardName]?[defaultName] as? Bool ?? false
    }
}

final class RebrandMigrationTests: XCTestCase {
    private var root: URL!
    private var oldDir: URL { root.appendingPathComponent("TermiusReimagined", isDirectory: true) }
    private var newDir: URL { root.appendingPathComponent("SwiftSSH", isDirectory: true) }
    private var log: OperationLog!
    private var keychain: FakeKeychain!
    private var files: LoggingFileSystem!
    private var defaults: FakeDefaults!
    private var logged: [String] = []

    private let names = RebrandMigration.Names.standard
    private var oldVaultKey: ItemKey { ItemKey(service: names.oldVaultKeyService, account: names.vaultKeyAccount) }
    private var newVaultKey: ItemKey { ItemKey(service: names.newVaultKeyService, account: names.vaultKeyAccount) }
    private let keyBytes = Data((0..<32).map { UInt8($0) })
    private let vaultBytes = Data("encrypted vault bytes".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebrand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log = OperationLog()
        keychain = FakeKeychain(log: log)
        files = LoggingFileSystem(log: log)
        defaults = FakeDefaults(standardName: names.newDefaultsDomain)
        logged = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeMigration() -> RebrandMigration {
        RebrandMigration(oldDirectory: oldDir, newDirectory: newDir, keychain: keychain, files: files,
                         defaults: defaults, names: names, log: { [unowned self] in self.logged.append($0) })
    }

    /// The old app's folder: vault.bin, workspaces.json, Badges/ (with a nested file) and run/.
    private func makeOldInstall(withKey: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: oldDir.appendingPathComponent("Badges/nested", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: oldDir.appendingPathComponent("run", isDirectory: true),
                               withIntermediateDirectories: true)
        try vaultBytes.write(to: oldDir.appendingPathComponent("vault.bin"))
        try Data("{\"version\":1,\"templates\":[]}".utf8).write(to: oldDir.appendingPathComponent("workspaces.json"))
        try Data("png".utf8).write(to: oldDir.appendingPathComponent("Badges/ubuntu.png"))
        try Data("{}".utf8).write(to: oldDir.appendingPathComponent("Badges/settings.json"))
        try Data("deep".utf8).write(to: oldDir.appendingPathComponent("Badges/nested/x.png"))
        try Data("askpass".utf8).write(to: oldDir.appendingPathComponent("run/askpass"))
        if withKey { keychain.items[oldVaultKey] = keyBytes }
    }

    private func newFile(_ path: String) -> Data? {
        try? Data(contentsOf: newDir.appendingPathComponent(path))
    }

    // MARK: Nothing to do

    func testNoOldVaultDoesNothingForTheVaultAndMarksDone() throws {
        let report = try makeMigration().migrateVaultIfNeeded()
        XCTAssertEqual(report.vault, .nothingToMigrate)
        XCTAssertTrue(log.entries.isEmpty, "\(log.entries)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path))
        XCTAssertTrue(defaults.bool(forKey: names.doneKey))
    }

    func testDoneMarkerSkipsEverything() throws {
        try makeOldInstall()
        defaults.set(true, forKey: names.doneKey)
        let migration = makeMigration()
        XCTAssertTrue(migration.isDone)
        let report = try migration.migrateVaultIfNeeded()
        XCTAssertEqual(report.vault, .alreadyDone)
        XCTAssertTrue(log.entries.isEmpty, "\(log.entries)")
        XCTAssertNil(newFile("vault.bin"))
    }

    func testExistingNewVaultFileSkipsVaultButStillCopiesSyncSecrets() throws {
        try makeOldInstall()
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data("new vault".utf8).write(to: newDir.appendingPathComponent("vault.bin"))
        keychain.items[ItemKey(service: names.oldSyncService, account: "apiKey")] = Data("api".utf8)

        let report = try makeMigration().migrateVaultIfNeeded()

        XCTAssertEqual(report.vault, .newVaultAlreadyExists)
        XCTAssertEqual(newFile("vault.bin"), Data("new vault".utf8))
        XCTAssertNil(newFile("workspaces.json"))
        XCTAssertFalse(log.entries.contains("keychain.read \(names.oldVaultKeyService) \(names.vaultKeyAccount)"))
        XCTAssertEqual(keychain.items[ItemKey(service: names.newSyncService, account: "apiKey")], Data("api".utf8))
        XCTAssertTrue(defaults.bool(forKey: names.doneKey))
    }

    func testExistingDifferentNewKeyIsKeptAndVaultIsNotCopied() throws {
        try makeOldInstall()
        let otherKey = Data(repeating: 9, count: 32)
        keychain.items[newVaultKey] = otherKey

        let report = try makeMigration().migrateVaultIfNeeded()

        XCTAssertEqual(report.vault, .newVaultKeyAlreadyExists)
        XCTAssertEqual(keychain.items[newVaultKey], otherKey)
        XCTAssertNil(newFile("vault.bin"))
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("fs.") }, "\(log.entries)")
    }

    func testExistingMatchingNewKeyResumesAnInterruptedMigration() throws {
        // A crash after the key was written but before vault.bin was renamed into place.
        try makeOldInstall()
        keychain.items[newVaultKey] = keyBytes

        let report = try makeMigration().migrateVaultIfNeeded()

        XCTAssertEqual(report.vault, .migrated)
        XCTAssertEqual(newFile("vault.bin"), vaultBytes)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("keychain.add \(self.names.newVaultKeyService) ") })
    }

    // MARK: Happy path

    func testMigratesKeyThenFilesThenSyncSecretsAndMarksDone() throws {
        try makeOldInstall()
        let syncVaultKey = Data(repeating: 7, count: 32)
        keychain.items[ItemKey(service: names.oldSyncService, account: "vaultKey")] = syncVaultKey
        keychain.items[ItemKey(service: names.oldSyncService, account: "apiKey")] = Data("api-key".utf8)

        let report = try makeMigration().migrateVaultIfNeeded()

        XCTAssertEqual(report.vault, .migrated)
        XCTAssertEqual(report.filesCopied, true)
        XCTAssertEqual(report.syncSecretsCopied, ["apiKey", "vaultKey"])
        XCTAssertTrue(report.syncSecretFailures.isEmpty)
        XCTAssertEqual(keychain.items[newVaultKey], keyBytes)
        XCTAssertEqual(keychain.kinds[newVaultKey], .vaultKey)
        XCTAssertEqual(keychain.items[ItemKey(service: names.newSyncService, account: "vaultKey")], syncVaultKey)
        XCTAssertEqual(keychain.kinds[ItemKey(service: names.newSyncService, account: "apiKey")], .syncSecret)
        XCTAssertEqual(newFile("vault.bin"), vaultBytes)
        XCTAssertEqual(newFile("workspaces.json"), Data("{\"version\":1,\"templates\":[]}".utf8))
        XCTAssertEqual(newFile("Badges/ubuntu.png"), Data("png".utf8))
        XCTAssertEqual(newFile("Badges/settings.json"), Data("{}".utf8))
        XCTAssertEqual(newFile("Badges/nested/x.png"), Data("deep".utf8))
        XCTAssertTrue(defaults.bool(forKey: names.doneKey))
    }

    func testRunFolderIsNotCopied() throws {
        try makeOldInstall()
        _ = try makeMigration().migrateVaultIfNeeded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("run").path))
    }

    func testOldFilesAndKeychainItemsStayAsBackup() throws {
        try makeOldInstall()
        keychain.items[ItemKey(service: names.oldSyncService, account: "apiKey")] = Data("api".utf8)
        _ = try makeMigration().migrateVaultIfNeeded()
        XCTAssertEqual(try Data(contentsOf: oldDir.appendingPathComponent("vault.bin")), vaultBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("Badges/ubuntu.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("workspaces.json").path))
        XCTAssertEqual(keychain.items[oldVaultKey], keyBytes)
        XCTAssertEqual(keychain.items[ItemKey(service: names.oldSyncService, account: "apiKey")], Data("api".utf8))
    }

    func testVaultKeyIsWrittenBeforeAnyFileIsCopiedAndVaultFileIsLast() throws {
        try makeOldInstall()
        _ = try makeMigration().migrateVaultIfNeeded()
        let keyAdd = try XCTUnwrap(log.entries.firstIndex(of: "keychain.add \(names.newVaultKeyService) \(names.vaultKeyAccount)"))
        let firstFileOp = try XCTUnwrap(log.entries.firstIndex { $0.hasPrefix("fs.") })
        XCTAssertLessThan(keyAdd, firstFileOp, "\(log.entries)")
        let lastMove = try XCTUnwrap(log.entries.lastIndex { $0.hasPrefix("fs.move") })
        XCTAssertEqual(log.entries[lastMove], "fs.move vault.bin", "vault.bin lands last, so its presence means all files were copied")
    }

    func testFilesAreCopiedToATempNameThenRenamed() throws {
        try makeOldInstall()
        files.failingMoves = ["vault.bin"]
        XCTAssertThrowsError(try makeMigration().migrateVaultIfNeeded())
        // The vault never appears half-written under its real name.
        XCTAssertNil(newFile("vault.bin"))
        XCTAssertFalse(defaults.bool(forKey: names.doneKey))

        // The next launch cleans the stale temp file and finishes.
        files.failingMoves = []
        let report = try makeMigration().migrateVaultIfNeeded()
        XCTAssertEqual(report.vault, .migrated)
        XCTAssertEqual(newFile("vault.bin"), vaultBytes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: newDir.path)
            .filter { $0.contains("migrating") }
        XCTAssertEqual(leftovers, [])
    }

    func testBadgesMergeIntoAnExistingFolderWithoutOverwriting() throws {
        try makeOldInstall()
        let badges = newDir.appendingPathComponent("Badges", isDirectory: true)
        try FileManager.default.createDirectory(at: badges, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: badges.appendingPathComponent("ubuntu.png"))

        _ = try makeMigration().migrateVaultIfNeeded()

        XCTAssertEqual(newFile("Badges/ubuntu.png"), Data("mine".utf8))
        XCTAssertEqual(newFile("Badges/settings.json"), Data("{}".utf8))
        XCTAssertEqual(newFile("Badges/nested/x.png"), Data("deep".utf8))
    }

    func testExistingNewWorkspacesFileIsNotOverwritten() throws {
        try makeOldInstall()
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newDir.appendingPathComponent("workspaces.json"))
        _ = try makeMigration().migrateVaultIfNeeded()
        XCTAssertEqual(newFile("workspaces.json"), Data("new".utf8))
        XCTAssertEqual(newFile("vault.bin"), vaultBytes)
    }

    func testMissingOptionalFilesAreFine() throws {
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try vaultBytes.write(to: oldDir.appendingPathComponent("vault.bin"))
        keychain.items[oldVaultKey] = keyBytes
        let report = try makeMigration().migrateVaultIfNeeded()
        XCTAssertEqual(report.vault, .migrated)
        XCTAssertEqual(newFile("vault.bin"), vaultBytes)
        XCTAssertNil(newFile("workspaces.json"))
    }

    // MARK: Old key unreadable: stop before anything is written

    func testDeniedOldKeyStopsBeforeCopyingAnything() throws {
        try makeOldInstall()
        keychain.deniedReads = [oldVaultKey]

        XCTAssertThrowsError(try makeMigration().migrateVaultIfNeeded()) { error in
            XCTAssertEqual(error as? RebrandMigrationError, .oldVaultKeyUnreadable)
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("keychain.add") }, "\(log.entries)")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("fs.") }, "\(log.entries)")
        XCTAssertNil(keychain.items[newVaultKey])
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path))
        XCTAssertFalse(defaults.bool(forKey: names.doneKey))
    }

    func testMissingOldKeyStopsBeforeCopyingAnything() throws {
        try makeOldInstall(withKey: false)
        XCTAssertThrowsError(try makeMigration().migrateVaultIfNeeded()) { error in
            XCTAssertEqual(error as? RebrandMigrationError, .oldVaultKeyMissing)
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("keychain.add") || $0.hasPrefix("fs.") })
        XCTAssertFalse(defaults.bool(forKey: names.doneKey))
    }

    func testMalformedOldKeyStops() throws {
        try makeOldInstall(withKey: false)
        keychain.items[oldVaultKey] = Data(repeating: 1, count: 5)
        XCTAssertThrowsError(try makeMigration().migrateVaultIfNeeded()) { error in
            XCTAssertEqual(error as? RebrandMigrationError, .oldVaultKeyInvalid)
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("keychain.add") || $0.hasPrefix("fs.") })
    }

    func testFailingToSaveTheNewKeyStopsBeforeCopyingFiles() throws {
        try makeOldInstall()
        keychain.failingAdds = [newVaultKey]
        XCTAssertThrowsError(try makeMigration().migrateVaultIfNeeded()) { error in
            guard case .newVaultKeyNotSaved = error as? RebrandMigrationError else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("fs.") }, "\(log.entries)")
        XCTAssertFalse(defaults.bool(forKey: names.doneKey))
    }

    func testDeniedThenAllowedOnRetryMigrates() throws {
        try makeOldInstall()
        keychain.deniedReads = [oldVaultKey]
        XCTAssertThrowsError(try makeMigration().migrateVaultIfNeeded())
        keychain.deniedReads = []
        XCTAssertEqual(try makeMigration().migrateVaultIfNeeded().vault, .migrated)
        XCTAssertEqual(newFile("vault.bin"), vaultBytes)
    }

    func testAFailedFileCopyStopsAndIsNotMarkedDone() throws {
        try makeOldInstall()
        files.failingCopies = ["workspaces.json"]
        XCTAssertThrowsError(try makeMigration().migrateVaultIfNeeded()) { error in
            guard case .fileCopyFailed(let name, _) = error as? RebrandMigrationError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, "workspaces.json")
        }
        XCTAssertNil(newFile("vault.bin"))
        XCTAssertFalse(defaults.bool(forKey: names.doneKey))
    }

    // MARK: The app never creates a fresh key while an old vault is unmigrated

    func testKeyIsLoadedOnlyAfterASuccessfulMigration() throws {
        try makeOldInstall()
        keychain.deniedReads = [oldVaultKey]
        var loadCalls = 0
        XCTAssertThrowsError(try makeMigration().migrateThenLoadKey { () -> Int in
            loadCalls += 1
            return 1
        })
        XCTAssertEqual(loadCalls, 0, "a fresh key must never be created while the old vault is unmigrated")

        keychain.deniedReads = []
        let result = try makeMigration().migrateThenLoadKey { () -> Data? in
            // At load time the migrated key is already under the new service.
            self.keychain.items[self.newVaultKey]
        }
        XCTAssertEqual(result.value, keyBytes)
        XCTAssertEqual(result.report?.vault, .migrated)
    }

    func testLoadSkipsMigrationOnceDone() throws {
        defaults.set(true, forKey: names.doneKey)
        let result = try makeMigration().migrateThenLoadKey { 42 }
        XCTAssertEqual(result.value, 42)
        XCTAssertNil(result.report)
    }

    // MARK: Sync secrets (non-fatal)

    func testSyncSecretFailuresAreLoggedNotFatal() throws {
        try makeOldInstall()
        let api = ItemKey(service: names.oldSyncService, account: "apiKey")
        let syncKey = ItemKey(service: names.oldSyncService, account: "vaultKey")
        keychain.items[api] = Data("super-secret-api-key".utf8)
        keychain.items[syncKey] = Data(repeating: 3, count: 32)
        keychain.deniedReads = [api]

        let report = try makeMigration().migrateVaultIfNeeded()

        XCTAssertEqual(report.vault, .migrated)
        XCTAssertEqual(report.syncSecretsCopied, ["vaultKey"])
        XCTAssertEqual(report.syncSecretFailures, ["apiKey"])
        XCTAssertNil(keychain.items[ItemKey(service: names.newSyncService, account: "apiKey")])
        XCTAssertTrue(defaults.bool(forKey: names.doneKey))
        XCTAssertTrue(logged.contains { $0.contains("apiKey") })
    }

    func testSyncListingFailureIsNotFatal() throws {
        try makeOldInstall()
        keychain.failAccountListing = true
        let report = try makeMigration().migrateVaultIfNeeded()
        XCTAssertEqual(report.vault, .migrated)
        XCTAssertTrue(report.syncSecretsCopied.isEmpty)
    }

    func testExistingNewSyncSecretIsNotOverwritten() throws {
        try makeOldInstall()
        keychain.items[ItemKey(service: names.oldSyncService, account: "apiKey")] = Data("old".utf8)
        keychain.items[ItemKey(service: names.newSyncService, account: "apiKey")] = Data("new".utf8)
        let report = try makeMigration().migrateVaultIfNeeded()
        XCTAssertEqual(keychain.items[ItemKey(service: names.newSyncService, account: "apiKey")], Data("new".utf8))
        XCTAssertTrue(report.syncSecretsCopied.isEmpty)
    }

    func testNoSecretEverReachesTheLogOrErrors() throws {
        try makeOldInstall()
        let secret = "super-secret-api-key"
        keychain.items[ItemKey(service: names.oldSyncService, account: "apiKey")] = Data(secret.utf8)
        keychain.failingAdds = [ItemKey(service: names.newSyncService, account: "apiKey")]
        _ = try makeMigration().migrateVaultIfNeeded()
        let keyHex = keyBytes.map { String(format: "%02x", $0) }.joined()
        for line in logged {
            XCTAssertFalse(line.contains(secret), line)
            XCTAssertFalse(line.contains(keyHex), line)
            XCTAssertFalse(line.contains(String(decoding: vaultBytes, as: UTF8.self)), line)
        }
        let errors: [RebrandMigrationError] = [.oldVaultKeyUnreadable, .oldVaultKeyMissing, .oldVaultKeyInvalid,
                                               .newVaultKeyNotSaved(detail: "x"), .fileCopyFailed(name: "vault.bin", detail: "y")]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testUnreadableKeyMessageTellsTheUserWhatToDo() {
        let message = RebrandMigrationError.oldVaultKeyUnreadable.errorDescription ?? ""
        XCTAssertTrue(message.contains("SwiftSSH couldn\u{2019}t read your Termius Reimagined vault key from the Keychain"), message)
        XCTAssertTrue(message.contains("Try Again"), message)
        XCTAssertTrue(message.contains("Always Allow"), message)
    }

    // MARK: Settings

    func testSettingsCopyOnlyMissingKeys() {
        defaults.domains[names.oldDefaultsDomain] = ["terminal.fontSize": 15, "sync.serverURL": "http://old",
                                                     "app.appearance": "dark"]
        defaults.domains[names.newDefaultsDomain] = ["app.appearance": "light"]

        let copied = makeMigration().migrateSettingsIfNeeded()

        XCTAssertEqual(copied, ["sync.serverURL", "terminal.fontSize"])
        let new = defaults.domains[names.newDefaultsDomain] ?? [:]
        XCTAssertEqual(new["terminal.fontSize"] as? Int, 15)
        XCTAssertEqual(new["sync.serverURL"] as? String, "http://old")
        XCTAssertEqual(new["app.appearance"] as? String, "light")
        // Settings alone don't finish the migration: the vault part sets the marker.
        XCTAssertFalse(defaults.bool(forKey: names.doneKey))
    }

    func testSettingsSkippedOnceDone() {
        defaults.domains[names.oldDefaultsDomain] = ["terminal.fontSize": 15]
        defaults.set(true, forKey: names.doneKey)
        XCTAssertEqual(makeMigration().migrateSettingsIfNeeded(), [])
        XCTAssertNil(defaults.domains[names.newDefaultsDomain]?["terminal.fontSize"])
    }

    func testSettingsWithoutOldDomainCopyNothing() {
        XCTAssertEqual(makeMigration().migrateSettingsIfNeeded(), [])
    }

    func testStandardNames() {
        XCTAssertEqual(names.oldVaultKeyService, "com.cwland.TermiusReimagined")
        XCTAssertEqual(names.newVaultKeyService, "com.cwland.SwiftSSH")
        XCTAssertEqual(names.vaultKeyAccount, "local-vault-key")
        XCTAssertEqual(names.oldSyncService, "com.cwland.TermiusReimagined.sync")
        XCTAssertEqual(names.newSyncService, "com.cwland.SwiftSSH.sync")
        XCTAssertEqual(names.oldDefaultsDomain, "com.cwland.TermiusReimagined")
        XCTAssertEqual(names.newDefaultsDomain, "com.cwland.SwiftSSH")
        XCTAssertEqual(names.doneKey, "migration.fromTermiusReimagined.done")
        XCTAssertEqual(RebrandMigration.oldFolderName, "TermiusReimagined")
        XCTAssertEqual(RebrandMigration.newFolderName, "SwiftSSH")
    }
}
