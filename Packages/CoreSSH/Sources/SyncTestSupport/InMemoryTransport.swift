import Foundation
import CoreModels
import SyncCore

/// Errors raised only by `InMemoryTransport` (the real HTTP transport has its own).
public enum InMemoryTransportError: Error, Equatable {
    /// Thrown once by `upsert` after `failNextUpsert()`.
    case injectedFailure
    /// More than `InMemoryTransport.maxBatch` records in one `upsert` (the server answers 400).
    case batchTooLarge
}

/// An in-process `SyncTransport` that behaves like the sync server:
/// - `putVault` throws `SyncError.vaultAlreadyExists` when a vault exists (server: 409).
/// - `rewrap` is a compare-and-swap on `oldWrappedKey` that keeps `vaultID`; it throws
///   `SyncError.noVault` without a vault (404) and `SyncError.vaultChanged` when stale (409).
/// - `upsert` applies `MergeRule` per record, gives only winners the next contiguous `seq`,
///   and returns the stored copy of every submitted id in first-submitted order.
/// - `fetch` returns records with `seq > since` ascending, `limit` clamped to 1...500,
///   an exact `hasMore`, and `nextSince` = last returned seq (or `since` when empty).
///
/// Test hooks: `failNextUpsert()`, `replaceVault(_:clearRecords:)`, call counters and
/// `storedRecords` for inspection.
public actor InMemoryTransport: SyncTransport {
    public static let maxBatch = 500
    public static let maxLimit = 500

    public private(set) var vault: VaultMetadata?
    private var recordsByID: [UUID: EncryptedRecord] = [:]
    private var lastSeq: Int64 = 0
    private var failUpsertOnce = false

    public private(set) var upsertCallCount = 0
    public private(set) var fetchCallCount = 0

    public init() {}

    /// Every stored record, ordered by `seq`.
    public var storedRecords: [EncryptedRecord] {
        recordsByID.values.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }
    }

    /// Makes the next `upsert` call throw `InMemoryTransportError.injectedFailure` without storing anything.
    public func failNextUpsert() {
        failUpsertOnce = true
    }

    /// Replaces the vault metadata as if the server had been wiped and re-created by someone else.
    /// Pass `nil` to simulate a server with no vault. By default the records are wiped too.
    public func replaceVault(_ metadata: VaultMetadata?, clearRecords: Bool = true) {
        vault = metadata
        if clearRecords {
            recordsByID = [:]
            lastSeq = 0
        }
    }

    // MARK: SyncTransport

    public func getVault() async throws -> VaultMetadata? {
        vault
    }

    public func putVault(_ metadata: VaultMetadata) async throws {
        guard vault == nil else { throw SyncError.vaultAlreadyExists }
        vault = metadata
    }

    public func rewrap(_ request: RewrapRequest) async throws -> VaultMetadata {
        guard var current = vault else { throw SyncError.noVault }
        guard current.wrappedKey == request.oldWrappedKey else { throw SyncError.vaultChanged }
        current.salt = request.salt
        current.iterations = request.iterations
        current.wrappedKey = request.wrappedKey
        vault = current
        return current
    }

    public func fetch(since: Int64, limit: Int) async throws -> RecordsPage {
        fetchCallCount += 1
        let limit = min(max(limit, 1), Self.maxLimit)
        let newer = storedRecords.filter { ($0.seq ?? 0) > since }
        let page = Array(newer.prefix(limit))
        return RecordsPage(records: page, nextSince: page.last?.seq ?? since, hasMore: newer.count > limit)
    }

    public func upsert(_ records: [EncryptedRecord]) async throws -> [EncryptedRecord] {
        upsertCallCount += 1
        if failUpsertOnce {
            failUpsertOnce = false
            throw InMemoryTransportError.injectedFailure
        }
        guard records.count <= Self.maxBatch else { throw InMemoryTransportError.batchTooLarge }
        var order: [UUID] = []
        for incoming in records {
            if !order.contains(incoming.id) { order.append(incoming.id) }
            var record = incoming
            // The server stores whole milliseconds.
            record.updatedAt = Date(timeIntervalSince1970:
                (incoming.updatedAt.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
            if let existing = recordsByID[record.id],
               !MergeRule.incomingWins((record.updatedAt, record.deviceID),
                                       over: (existing.updatedAt, existing.deviceID)) {
                continue
            }
            lastSeq += 1
            record.seq = lastSeq
            recordsByID[record.id] = record
        }
        return order.compactMap { recordsByID[$0] }
    }
}
