import Foundation
import SyncCore

// MARK: - What the migration needs from the system

/// What a migrated Keychain item is for; the app picks its label and accessibility from this.
public enum RebrandMigrationKeychainItemKind: Sendable, Equatable {
    /// The local vault's key (`KeychainVaultKeyProvider`'s item).
    case vaultKey
    /// A sync secret (`KeychainSyncSecretsStore`'s items: the sync vault key and the API key).
    case syncSecret
}

/// Generic-password Keychain access for the rebrand migration. Implementations must never put an
/// item's data in an error or a log line (an `OSStatus` is fine).
public protocol RebrandMigrationKeychain {
    /// The item's data, nil when no such item exists. Throws when it exists but can't be read
    /// (for example the user clicked Deny on the access prompt).
    func readData(service: String, account: String) throws -> Data?
    /// Whether the item exists. Reads attributes only, so it never raises an access prompt.
    func contains(service: String, account: String) throws -> Bool
    /// The accounts of every generic password under `service` (attributes only, no prompt).
    func accounts(service: String) throws -> [String]
    /// Adds a new item (this device only, never synchronized). Throws if it can't be added,
    /// including when the item already exists.
    func add(_ data: Data, service: String, account: String, kind: RebrandMigrationKeychainItemKind) throws
}

/// The few file operations the migration uses. `FileManagerMigrationFileSystem` is the real one.
public protocol RebrandMigrationFileSystem {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    /// Names of the folder's entries (not full paths).
    func contentsOfDirectory(at url: URL) throws -> [String]
    /// Creates the folder and any missing parents; an existing folder is fine.
    func createDirectory(at url: URL) throws
    /// Copies a file or a whole folder. Fails if `destination` exists.
    func copyItem(at source: URL, to destination: URL) throws
    /// Renames within one volume. Fails if `destination` exists.
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
}

/// UserDefaults as the migration sees it. `UserDefaults` conforms as is.
public protocol RebrandMigrationDefaults {
    /// The stored keys of one app's preferences (no registered or global values).
    func persistentDomain(forName domainName: String) -> [String: Any]?
    /// Writes to this app's own preferences.
    func set(_ value: Any?, forKey defaultName: String)
    func bool(forKey defaultName: String) -> Bool
}

extension UserDefaults: RebrandMigrationDefaults {}

/// `FileManager.default` for the migration.
public struct FileManagerMigrationFileSystem: RebrandMigrationFileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func contentsOfDirectory(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Results

/// Why the migration stopped. Nothing secret is ever part of these (details are an `OSStatus`
/// description or a file error), and the old app's files and Keychain items are never changed.
public enum RebrandMigrationError: Error, Equatable, LocalizedError {
    /// The old vault key exists but couldn't be read (access denied on the prompt, or a Keychain error).
    case oldVaultKeyUnreadable
    /// There is an old vault but no old vault key in the Keychain.
    case oldVaultKeyMissing
    /// The old vault key isn't a 32-byte key.
    case oldVaultKeyInvalid
    /// The key couldn't be saved under SwiftSSH's Keychain service.
    case newVaultKeyNotSaved(detail: String)
    /// A file or folder couldn't be copied into SwiftSSH's folder.
    case fileCopyFailed(name: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .oldVaultKeyUnreadable:
            "SwiftSSH couldn\u{2019}t read your Termius Reimagined vault key from the Keychain, so your vault "
                + "hasn\u{2019}t been moved over yet. Nothing was changed. Click Try Again and choose Always Allow "
                + "when macOS asks."
        case .oldVaultKeyMissing:
            "SwiftSSH found your Termius Reimagined vault, but not its key in the Keychain (item "
                + "\u{201C}com.cwland.TermiusReimagined\u{201D}), so the vault can\u{2019}t be moved over. Nothing "
                + "was changed: the old vault is still in Application Support/TermiusReimagined. Check that "
                + "the item is in Keychain Access, then click Try Again."
        case .oldVaultKeyInvalid:
            "SwiftSSH found your Termius Reimagined vault key in the Keychain, but it isn\u{2019}t a valid vault "
                + "key, so the vault can\u{2019}t be moved over. Nothing was changed: the old vault is still in "
                + "Application Support/TermiusReimagined."
        case .newVaultKeyNotSaved(let detail):
            "SwiftSSH read your Termius Reimagined vault key but couldn\u{2019}t save it under its new name in "
                + "the Keychain (\(detail)). No files were copied. Click Try Again."
        case .fileCopyFailed(let name, let detail):
            "SwiftSSH couldn\u{2019}t copy \(name) from Application Support/TermiusReimagined to "
                + "Application Support/SwiftSSH (\(detail)). Your old files are unchanged. Click Try Again."
        }
    }
}

/// What the vault part of the migration did.
public struct RebrandMigrationReport: Equatable, Sendable {
    public enum Vault: Equatable, Sendable {
        /// The done marker was already set: nothing ran.
        case alreadyDone
        /// No old vault file: nothing to bring over.
        case nothingToMigrate
        /// SwiftSSH already has a vault file; the old one was left alone.
        case newVaultAlreadyExists
        /// SwiftSSH already has a different vault key; it was kept and the old vault was not copied.
        case newVaultKeyAlreadyExists
        /// The key and files were brought over.
        case migrated
    }

    public var vault: Vault
    /// Whether any file or folder was copied into SwiftSSH's folder (the app then reloads what it read early).
    public var filesCopied: Bool = false
    /// Accounts of the sync secrets copied to the new service, sorted.
    public var syncSecretsCopied: [String] = []
    /// Accounts of the sync secrets that couldn't be copied (sync asks for them again), sorted.
    public var syncSecretFailures: [String] = []

    public init(vault: Vault) {
        self.vault = vault
    }
}

// MARK: - The migration

/// One-time move from "Termius Reimagined" to SwiftSSH on first launch: copies the vault key,
/// the vault and its neighbours, the sync secrets and the settings to their new names. The old
/// files and Keychain items are never changed or deleted, so they stay as a backup.
///
/// Order (`migrateVaultIfNeeded`): (a) done already or nothing to do; (b) the vault key first,
/// stopping if it can't be read; (c) the files, each copied to a temporary name and renamed into
/// place, `vault.bin` last; (d) the sync secrets, failures only logged; then the done marker.
/// Settings (`migrateSettingsIfNeeded`) are copied separately and earlier, before the app's settings
/// objects read them.
public struct RebrandMigration {
    /// Keychain services, accounts and defaults names, old and new.
    public struct Names: Sendable, Equatable {
        public var oldVaultKeyService: String
        public var newVaultKeyService: String
        /// The vault key's account (unchanged by the rebrand).
        public var vaultKeyAccount: String
        public var oldSyncService: String
        public var newSyncService: String
        public var oldDefaultsDomain: String
        /// This app's own defaults domain (its bundle identifier).
        public var newDefaultsDomain: String
        /// Bool in the new defaults: set once the migration finished.
        public var doneKey: String

        public static let standard = Names(
            oldVaultKeyService: "com.cwland.TermiusReimagined",
            newVaultKeyService: "com.cwland.SwiftSSH",
            vaultKeyAccount: "local-vault-key",
            oldSyncService: "com.cwland.TermiusReimagined.sync",
            newSyncService: "com.cwland.SwiftSSH.sync",
            oldDefaultsDomain: "com.cwland.TermiusReimagined",
            newDefaultsDomain: "com.cwland.SwiftSSH",
            doneKey: "migration.fromTermiusReimagined.done"
        )
    }

    /// The old app's folder in Application Support.
    public static let oldFolderName = "TermiusReimagined"
    /// SwiftSSH's folder in Application Support.
    public static let newFolderName = "SwiftSSH"
    static let vaultFileName = "vault.bin"
    /// Copied before `vault.bin` (whose arrival means every file is in place). `run/` is never copied.
    static let otherItemNames = ["workspaces.json", "Badges"]

    let oldDirectory: URL
    let newDirectory: URL
    let keychain: any RebrandMigrationKeychain
    let files: any RebrandMigrationFileSystem
    let defaults: any RebrandMigrationDefaults
    let names: Names
    let log: (String) -> Void

    /// `log` receives plain progress lines; they never contain a secret.
    public init(oldDirectory: URL, newDirectory: URL, keychain: any RebrandMigrationKeychain,
                files: any RebrandMigrationFileSystem = FileManagerMigrationFileSystem(),
                defaults: any RebrandMigrationDefaults, names: Names = .standard,
                log: @escaping (String) -> Void = { _ in }) {
        self.oldDirectory = oldDirectory
        self.newDirectory = newDirectory
        self.keychain = keychain
        self.files = files
        self.defaults = defaults
        self.names = names
        self.log = log
    }

    /// Whether the migration already finished on this Mac.
    public var isDone: Bool {
        defaults.bool(forKey: names.doneKey)
    }

    // MARK: Settings

    /// Copies the old app's stored settings into this app's defaults, only keys not already set
    /// here. Skipped once the migration is done. Returns the copied keys, sorted. Doesn't set the
    /// done marker (the vault part does), so it may run on several launches; keys set by then are kept.
    @discardableResult
    public func migrateSettingsIfNeeded() -> [String] {
        guard !isDone, let old = defaults.persistentDomain(forName: names.oldDefaultsDomain) else { return [] }
        let existing = defaults.persistentDomain(forName: names.newDefaultsDomain) ?? [:]
        var copied: [String] = []
        for (key, value) in old where existing[key] == nil && key != names.doneKey {
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        copied.sort()
        if !copied.isEmpty {
            log("Rebrand migration: copied \(copied.count) settings from Termius Reimagined.")
        }
        return copied
    }

    // MARK: Vault

    /// Runs the vault part of the migration when it isn't done, then `loadKey`. If the migration
    /// throws, `loadKey` is never called: the app must not create a fresh vault key while an old
    /// vault exists unmigrated (the copied vault would then be unreadable). `report` is nil when the
    /// migration was already done.
    public func migrateThenLoadKey<Value>(_ loadKey: () throws -> Value) throws -> (report: RebrandMigrationReport?, value: Value) {
        var report: RebrandMigrationReport?
        if !isDone {
            report = try migrateVaultIfNeeded()
        }
        return (report, try loadKey())
    }

    /// The vault key, files and sync secrets (steps a–d), then the done marker. Throws, without
    /// setting the marker, when the vault key can't be brought over or a file can't be copied.
    public func migrateVaultIfNeeded() throws -> RebrandMigrationReport {
        guard !isDone else { return RebrandMigrationReport(vault: .alreadyDone) }

        let oldVault = oldDirectory.appendingPathComponent(Self.vaultFileName, isDirectory: false)
        let newVault = newDirectory.appendingPathComponent(Self.vaultFileName, isDirectory: false)

        // (a) Nothing to bring over.
        guard files.fileExists(at: oldVault) else {
            log("Rebrand migration: no Termius Reimagined vault on this Mac; nothing to migrate.")
            markDone()
            return RebrandMigrationReport(vault: .nothingToMigrate)
        }

        var report: RebrandMigrationReport
        if files.fileExists(at: newVault) {
            // (a) SwiftSSH already has a vault: leave both alone.
            log("Rebrand migration: SwiftSSH already has a vault file; the Termius Reimagined vault was left alone.")
            report = RebrandMigrationReport(vault: .newVaultAlreadyExists)
        } else if try migrateVaultKey() {
            // (c) Files, only once the key is safely under its new name.
            report = RebrandMigrationReport(vault: .migrated)
            report.filesCopied = try copyFiles(newVault: newVault)
        } else {
            report = RebrandMigrationReport(vault: .newVaultKeyAlreadyExists)
        }

        // (d) Sync secrets: failures are only logged; sync asks for the API key again.
        let (copied, failed) = migrateSyncSecrets()
        report.syncSecretsCopied = copied
        report.syncSecretFailures = failed

        markDone()
        log("Rebrand migration from Termius Reimagined finished.")
        return report
    }

    private func markDone() {
        defaults.set(true, forKey: names.doneKey)
    }

    /// (b) Reads the old vault key and saves it under the new service. Returns false when a
    /// different key is already saved under the new service (it is kept; the vault isn't copied).
    /// The same key already there is an interrupted earlier run: carry on with the files.
    private func migrateVaultKey() throws -> Bool {
        let oldData: Data?
        do {
            oldData = try keychain.readData(service: names.oldVaultKeyService, account: names.vaultKeyAccount)
        } catch {
            log("Rebrand migration: couldn\u{2019}t read the Termius Reimagined vault key (\(Self.describe(error))).")
            throw RebrandMigrationError.oldVaultKeyUnreadable
        }
        guard let oldKey = oldData else {
            log("Rebrand migration: the Termius Reimagined vault key is not in the Keychain.")
            throw RebrandMigrationError.oldVaultKeyMissing
        }
        guard oldKey.count == VaultKey.rawByteCount else {
            log("Rebrand migration: the Termius Reimagined vault key has the wrong length.")
            throw RebrandMigrationError.oldVaultKeyInvalid
        }

        let newExists: Bool
        do {
            newExists = try keychain.contains(service: names.newVaultKeyService, account: names.vaultKeyAccount)
        } catch {
            throw RebrandMigrationError.newVaultKeyNotSaved(detail: Self.describe(error))
        }
        if newExists {
            let newKey: Data?
            do {
                newKey = try keychain.readData(service: names.newVaultKeyService, account: names.vaultKeyAccount)
            } catch {
                throw RebrandMigrationError.newVaultKeyNotSaved(detail: Self.describe(error))
            }
            if newKey == oldKey {
                log("Rebrand migration: the vault key is already under SwiftSSH\u{2019}s name; finishing the file copy.")
                return true
            }
            log("Rebrand migration: SwiftSSH already has a different vault key; it was kept and the Termius Reimagined vault was not copied.")
            return false
        }

        do {
            try keychain.add(oldKey, service: names.newVaultKeyService, account: names.vaultKeyAccount, kind: .vaultKey)
        } catch {
            log("Rebrand migration: couldn\u{2019}t save the vault key under SwiftSSH\u{2019}s name (\(Self.describe(error))).")
            throw RebrandMigrationError.newVaultKeyNotSaved(detail: Self.describe(error))
        }
        log("Rebrand migration: vault key copied to SwiftSSH\u{2019}s Keychain item.")
        return true
    }

    /// (c) `workspaces.json` and `Badges/` (only what's missing), then `vault.bin`. Returns whether
    /// anything was copied.
    private func copyFiles(newVault: URL) throws -> Bool {
        do {
            try files.createDirectory(at: newDirectory)
        } catch {
            throw RebrandMigrationError.fileCopyFailed(name: Self.newFolderName, detail: Self.describe(error))
        }
        var copiedAny = false
        for name in Self.otherItemNames {
            let source = oldDirectory.appendingPathComponent(name)
            guard files.fileExists(at: source) else { continue }
            if try copyMissing(from: source, to: newDirectory.appendingPathComponent(name), displayName: name) {
                copiedAny = true
            }
        }
        let oldVault = oldDirectory.appendingPathComponent(Self.vaultFileName, isDirectory: false)
        if try copyMissing(from: oldVault, to: newVault, displayName: Self.vaultFileName) {
            copiedAny = true
        }
        log("Rebrand migration: files copied to Application Support/SwiftSSH.")
        return copiedAny
    }

    /// Copies `source` to `destination` unless it is already there; a folder that already exists is
    /// merged entry by entry (existing files win). Each copy goes to a temporary name first and is then
    /// renamed, so a crash never leaves a half-written file under the real name.
    private func copyMissing(from source: URL, to destination: URL, displayName: String) throws -> Bool {
        if files.isDirectory(at: source), files.isDirectory(at: destination) {
            let entries: [String]
            do {
                entries = try files.contentsOfDirectory(at: source)
            } catch {
                throw RebrandMigrationError.fileCopyFailed(name: displayName, detail: Self.describe(error))
            }
            var copiedAny = false
            for entry in entries.sorted() {
                if try copyMissing(from: source.appendingPathComponent(entry),
                                   to: destination.appendingPathComponent(entry),
                                   displayName: displayName + "/" + entry) {
                    copiedAny = true
                }
            }
            return copiedAny
        }
        guard !files.fileExists(at: destination) else { return false }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).swiftssh-migrating")
        do {
            if files.fileExists(at: temporary) {
                try files.removeItem(at: temporary) // left by an interrupted run
            }
            try files.copyItem(at: source, to: temporary)
            try files.moveItem(at: temporary, to: destination)
        } catch {
            try? files.removeItem(at: temporary)
            log("Rebrand migration: couldn\u{2019}t copy \(displayName) (\(Self.describe(error))).")
            throw RebrandMigrationError.fileCopyFailed(name: displayName, detail: Self.describe(error))
        }
        return true
    }

    /// (d) Every item under the old sync service that isn't already under the new one.
    private func migrateSyncSecrets() -> (copied: [String], failed: [String]) {
        let accounts: [String]
        do {
            accounts = try keychain.accounts(service: names.oldSyncService)
        } catch {
            log("Rebrand migration: couldn\u{2019}t list the Termius Reimagined sync items (\(Self.describe(error))); sync will ask for its API key again.")
            return ([], [])
        }
        var copied: [String] = []
        var failed: [String] = []
        for account in accounts.sorted() {
            do {
                if try keychain.contains(service: names.newSyncService, account: account) { continue }
                guard let data = try keychain.readData(service: names.oldSyncService, account: account) else { continue }
                try keychain.add(data, service: names.newSyncService, account: account, kind: .syncSecret)
                copied.append(account)
            } catch {
                log("Rebrand migration: couldn\u{2019}t copy the sync item \u{201C}\(account)\u{201D} (\(Self.describe(error))); sync will ask for it again.")
                failed.append(account)
            }
        }
        if !copied.isEmpty {
            log("Rebrand migration: copied \(copied.count) sync Keychain items.")
        }
        return (copied, failed)
    }

    /// An error's description for logs and messages. The protocols promise errors carry no secret.
    private static func describe(_ error: any Error) -> String {
        error.localizedDescription
    }
}
