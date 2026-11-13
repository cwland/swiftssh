import Foundation
import Crypto
import CoreModels

#if !canImport(CryptoKit)
// swift-crypto's own `SymmetricKey` (used off Apple platforms) is an immutable value type but
// isn't declared `Sendable`; CryptoKit's is. Needed to hand keys across actor boundaries.
extension SymmetricKey: @retroactive @unchecked Sendable {}
#endif

/// A decrypted record as the local store sees it: the model's JSON (`CoreJSON`) plus the
/// metadata the merge rule needs.
public struct PlainRecord: Equatable, Sendable {
    public var id: UUID
    public var type: SyncRecordType
    public var updatedAt: Date
    public var deleted: Bool
    public var deviceID: String
    public var payload: Data

    public init(id: UUID, type: SyncRecordType, updatedAt: Date, deleted: Bool, deviceID: String, payload: Data) {
        self.id = id
        self.type = type
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.deviceID = deviceID
        self.payload = payload
    }

    public init<M: SyncableModel>(_ model: M, deviceID: String) throws {
        self.init(id: model.id, type: M.recordType, updatedAt: model.updatedAt, deleted: model.deleted,
                  deviceID: deviceID, payload: try CoreJSON.encoder.encode(model))
    }

    public func decode<M: SyncableModel>(_: M.Type) throws -> M {
        try CoreJSON.decoder.decode(M.self, from: payload)
    }
}

/// The sync server as the engine sees it. Implementations map HTTP 404 on `GET /vault` to
/// `nil`, 409 on `PUT /vault` to `SyncError.vaultAlreadyExists`, and on rewrap 404 to
/// `SyncError.noVault` and 409 (stale `oldWrappedKey`) to `SyncError.vaultChanged`.
public protocol SyncTransport: Sendable {
    func getVault() async throws -> VaultMetadata?
    func putVault(_ metadata: VaultMetadata) async throws
    func rewrap(_ request: RewrapRequest) async throws -> VaultMetadata
    func fetch(since: Int64, limit: Int) async throws -> RecordsPage
    /// Returns the server's stored copy of every submitted id.
    func upsert(_ records: [EncryptedRecord]) async throws -> [EncryptedRecord]
}

/// The app's local database as the engine sees it.
public protocol SyncLocalStore: Sendable {
    /// Records changed locally and not yet confirmed by the server.
    func dirtyRecords() async throws -> [PlainRecord]
    /// Clears the dirty flag of each id, but only if its `updatedAt` still equals the given date
    /// (a record edited while the push was in flight stays dirty).
    func markClean(_ ids: [UUID: Date]) async throws
    /// Applies pulled records; the store applies `MergeRule` against its own copies.
    func apply(_ records: [PlainRecord]) async throws
    func markAllDirty() async throws
    func removeAll() async throws
    var syncState: SyncState { get async }
    func setSyncState(_ state: SyncState) async throws
}

public struct SyncState: Codable, Equatable, Sendable {
    public var vaultID: UUID?
    public var lastSeq: Int64

    public init(vaultID: UUID?, lastSeq: Int64) {
        self.vaultID = vaultID
        self.lastSeq = lastSeq
    }
}

public enum JoinMode: Sendable {
    /// Keep local records and upload them into the vault.
    case merge
    /// Discard local records and take the vault's contents.
    case replace
}

public enum SyncError: Error, Equatable {
    case wrongPassphrase, noVault, vaultAlreadyExists, vaultChanged, locked
    /// A pulled record failed authentication (corrupted or tampered with on the server).
    case tamperedRecord(UUID)
}

public struct SyncReport: Equatable, Sendable {
    /// Records sent to the server.
    public var pushed: Int
    /// Records received from the server (this device's own pushes come back too).
    public var pulled: Int

    public init(pushed: Int, pulled: Int) {
        self.pushed = pushed
        self.pulled = pulled
    }
}

/// Creates or joins the end-to-end-encrypted vault and syncs the local store with the server.
/// Only `EncryptedRecord`s sealed with the vault key ever leave the engine.
///
/// `sync`, `createVault`, `join` and `changePassphrase` are serialized: each waits (FIFO) for
/// the previous one to finish, so the actor's reentrancy at `await`s can't interleave them.
public actor SyncEngine {
    public static let batchSize = 500

    private let transport: any SyncTransport
    private let store: any SyncLocalStore
    private let deviceID: String
    private let iterations: Int
    private var vaultKey: SymmetricKey?
    private var operationRunning = false
    private var waitingOperations: [CheckedContinuation<Void, Never>] = []

    public init(transport: any SyncTransport, store: any SyncLocalStore, deviceID: String,
                iterations: Int = VaultCrypto.defaultIterations) {
        self.transport = transport
        self.store = store
        self.deviceID = deviceID
        self.iterations = iterations
    }

    public func vaultExists() async throws -> Bool {
        try await transport.getVault() != nil
    }

    /// Creates a new vault on the server, unlocks the engine with its key and marks every local
    /// record dirty so the next `sync()` uploads everything. Throws `.vaultAlreadyExists`.
    public func createVault(passphrase: String) async throws -> SymmetricKey {
        await beginOperation()
        defer { endOperation() }
        let salt = VaultCrypto.randomSalt()
        let key = VaultCrypto.newVaultKey()
        let wrapping = try VaultCrypto.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let metadata = VaultMetadata(vaultID: UUID(), salt: salt, iterations: iterations,
                                     wrappedKey: try VaultCrypto.wrap(vaultKey: key, with: wrapping))
        try await transport.putVault(metadata)
        try await store.setSyncState(SyncState(vaultID: metadata.vaultID, lastSeq: 0))
        try await store.markAllDirty()
        vaultKey = key
        return key
    }

    /// Joins the server's vault. A wrong passphrase throws `.wrongPassphrase` before anything
    /// is changed locally or remotely.
    public func join(passphrase: String, mode: JoinMode) async throws -> SymmetricKey {
        await beginOperation()
        defer { endOperation() }
        guard let metadata = try await transport.getVault() else { throw SyncError.noVault }
        let key = try Self.unwrap(metadata, passphrase: passphrase)
        switch mode {
        case .replace: try await store.removeAll()
        case .merge: try await store.markAllDirty()
        }
        try await store.setSyncState(SyncState(vaultID: metadata.vaultID, lastSeq: 0))
        vaultKey = key
        return key
    }

    /// Unlocks with a vault key the app kept (e.g. in the Keychain).
    public func unlock(with key: SymmetricKey) {
        vaultKey = key
    }

    /// Re-wraps the vault key under `new` with a fresh salt. The vault key itself, and so every
    /// stored record, is unchanged.
    public func changePassphrase(old: String, new: String) async throws {
        await beginOperation()
        defer { endOperation() }
        guard let metadata = try await transport.getVault() else { throw SyncError.noVault }
        guard metadata.vaultID == (await store.syncState).vaultID else { throw SyncError.vaultChanged }
        let key = try Self.unwrap(metadata, passphrase: old)
        let salt = VaultCrypto.randomSalt()
        let wrapping = try VaultCrypto.deriveKey(passphrase: new, salt: salt, iterations: iterations)
        _ = try await transport.rewrap(RewrapRequest(oldWrappedKey: metadata.wrappedKey, salt: salt,
                                                     iterations: iterations,
                                                     wrappedKey: try VaultCrypto.wrap(vaultKey: key, with: wrapping)))
    }

    /// Pushes dirty records, then pulls everything newer than `syncState.lastSeq`.
    /// Throws `.locked` without a key and `.vaultChanged` (before pushing) when the server's
    /// vault is gone or is a different vault.
    public func sync() async throws -> SyncReport {
        await beginOperation()
        defer { endOperation() }
        guard let key = vaultKey else { throw SyncError.locked }
        var state = await store.syncState
        guard let vault = try await transport.getVault(), vault.vaultID == state.vaultID else {
            throw SyncError.vaultChanged
        }

        var report = SyncReport(pushed: 0, pulled: 0)
        let dirty = try await store.dirtyRecords()
        var start = 0
        while start < dirty.count {
            let batch = dirty[start ..< min(start + Self.batchSize, dirty.count)]
            let sealed = try batch.map { record in
                EncryptedRecord(id: record.id, type: record.type, updatedAt: record.updatedAt,
                                deleted: record.deleted, deviceID: record.deviceID,
                                ciphertext: try VaultCrypto.seal(record.payload, id: record.id, type: record.type,
                                                                 updatedAt: record.updatedAt, deleted: record.deleted,
                                                                 deviceID: record.deviceID, key: key))
            }
            _ = try await transport.upsert(sealed)
            try await store.markClean(Dictionary(batch.map { ($0.id, $0.updatedAt) },
                                                 uniquingKeysWith: { _, last in last }))
            report.pushed += batch.count
            start += Self.batchSize
        }

        var hasMore = true
        while hasMore {
            let page = try await transport.fetch(since: state.lastSeq, limit: Self.batchSize)
            let plain = try page.records.map { record in
                let payload: Data
                do {
                    payload = try VaultCrypto.open(record.ciphertext, id: record.id, type: record.type,
                                                   updatedAt: record.updatedAt, deleted: record.deleted,
                                                   deviceID: record.deviceID, key: key)
                } catch VaultCryptoError.tamperedRecord {
                    throw SyncError.tamperedRecord(record.id)
                }
                return PlainRecord(id: record.id, type: record.type, updatedAt: record.updatedAt,
                                   deleted: record.deleted, deviceID: record.deviceID, payload: payload)
            }
            try await store.apply(plain)
            state.lastSeq = page.nextSince
            try await store.setSyncState(state)
            report.pulled += plain.count
            hasMore = page.hasMore
        }
        return report
    }

    /// Waits until no other operation is running, then marks one as running (FIFO).
    private func beginOperation() async {
        if operationRunning {
            await withCheckedContinuation { waitingOperations.append($0) }
        } else {
            operationRunning = true
        }
    }

    /// Hands the running slot to the next waiter, or frees it.
    private func endOperation() {
        if waitingOperations.isEmpty {
            operationRunning = false
        } else {
            waitingOperations.removeFirst().resume()
        }
    }

    private static func unwrap(_ metadata: VaultMetadata, passphrase: String) throws -> SymmetricKey {
        let wrapping = try VaultCrypto.deriveKey(passphrase: passphrase, salt: metadata.salt,
                                                 iterations: metadata.iterations)
        do {
            return try VaultCrypto.unwrap(metadata.wrappedKey, with: wrapping)
        } catch VaultCryptoError.wrongPassphrase {
            throw SyncError.wrongPassphrase
        }
    }
}
