import Foundation
import Observation
import CoreModels
import SyncCore

public enum LocalVaultError: Error, Equatable, Sendable, LocalizedError {
    /// The vault file's format version is not one this build can read.
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "The vault file uses format version \(version), which this version of the app can't read. "
                + "Update the app to open it."
        }
    }
}

/// The app's local, observable record store. Records are kept as `PlainRecord`s in insertion
/// order and decoded on query. Every local change marks the record dirty and is persisted; deletes
/// are tombstones. `LocalVaultSyncStore` exposes it to `SyncEngine`; records applied from a pull
/// bump `revision` but are not dirty and don't call `localChangeHandler`.
@MainActor @Observable
public final class LocalVault {
    public private(set) var revision = 0
    public private(set) var lastSaveError: Error?
    public private(set) var deviceID: String

    @ObservationIgnored private let persistence: any VaultPersistence
    @ObservationIgnored private var records: [UUID: PlainRecord] = [:]
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var persistInFlight = false
    @ObservationIgnored private var persistWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var queuedPersists: [Int: Task<Void, Error>] = [:]
    @ObservationIgnored private var persistCounter = 0
    @ObservationIgnored private var syncState = SyncState(vaultID: nil, lastSeq: 0)
    /// While a merge join is pending: the ids this Mac had before it started (persisted).
    @ObservationIgnored private var mergeJoinLocalIDs: Set<UUID>?
    /// Hosts the user set back to "Automatic" OS; the next connection probes them once more.
    /// In memory only: it is an app-session hint, not synced data.
    @ObservationIgnored private var osProbeRequests: Set<UUID> = []
    /// Called after every local change (save, saveNow, delete), never for pulled records or other
    /// sync bookkeeping. `SyncCoordinator` uses it to schedule a debounced sync.
    @ObservationIgnored var localChangeHandler: (@MainActor () -> Void)?

    /// Asks for one more OS probe of this host on its next connection.
    public func requestOSProbe(for hostID: UUID) { osProbeRequests.insert(hostID) }

    /// True once per `requestOSProbe(for:)`; clears the request.
    public func takeOSProbeRequest(for hostID: UUID) -> Bool { osProbeRequests.remove(hostID) != nil }

    private init(persistence: any VaultPersistence, deviceID: String) {
        self.persistence = persistence
        self.deviceID = deviceID
    }

    public static func open(persistence: any VaultPersistence,
                            newDeviceID: () -> String = { UUID().uuidString }) async throws -> LocalVault {
        if let contents = try await persistence.load() {
            guard contents.version == 1 else { throw LocalVaultError.unsupportedVersion(contents.version) }
            let vault = LocalVault(persistence: persistence, deviceID: contents.deviceID)
            vault.syncState = contents.syncState
            vault.dirty = contents.dirty
            vault.mergeJoinLocalIDs = contents.mergeJoinLocalIDs
            for record in contents.records where vault.records[record.id] == nil {
                vault.records[record.id] = record
                vault.order.append(record.id)
            }
            return vault
        }
        return LocalVault(persistence: persistence, deviceID: newDeviceID())
    }

    /// Non-deleted records of type `M`, in insertion order.
    /// How many records of `types` are not deleted (sidebar counts). Observed through `revision`.
    public func liveCount(of types: Set<SyncRecordType>) -> Int {
        _ = revision
        return records.values.reduce(0) { $0 + (types.contains($1.type) && !$1.deleted ? 1 : 0) }
    }

    public func all<M: SyncableModel>(_: M.Type) -> [M] {
        order.compactMap { id in
            guard let record = records[id], record.type == M.recordType, !record.deleted else { return nil }
            return try? record.decode(M.self)
        }
    }

    /// Deleted records (tombstones) of type `M` that can still be read, in insertion order. A tombstone
    /// keeps the record's last contents until it is wiped (see `RecentlyDeletedViewModel`).
    public func deletedRecords<M: SyncableModel>(_: M.Type) -> [M] {
        _ = revision
        return order.compactMap { id in
            guard let record = records[id], record.type == M.recordType, record.deleted else { return nil }
            return try? record.decode(M.self)
        }
    }

    public func get<M: SyncableModel>(_: M.Type, id: UUID) -> M? {
        guard let record = records[id], record.type == M.recordType, !record.deleted else { return nil }
        return try? record.decode(M.self)
    }

    /// Stores `model` with a new `updatedAt`, marks it dirty and persists. On a persistence
    /// failure the change stays in memory, `lastSaveError` is set and the error is rethrown.
    @discardableResult
    public func save<M: SyncableModel>(_ model: M) async throws -> M {
        let stored = try apply(model)
        try await enqueuePersist().value
        return stored
    }

    /// Synchronous `save` for callers that cannot await, such as property setters: the change
    /// is applied in memory before returning and its persist is queued behind earlier ones.
    /// Persist failures are reported through `lastSaveError`; `flush()` waits for the queue.
    @discardableResult
    public func saveNow<M: SyncableModel>(_ model: M) -> M {
        do {
            let stored = try apply(model)
            enqueuePersist()
            return stored
        } catch {
            lastSaveError = error
            return model
        }
    }

    /// Waits until every persist queued so far, including ones queued while waiting, is done.
    /// If the last completed write failed, tries once more; the outcome is in `lastSaveError`.
    public func flush() async {
        await drainQueuedPersists()
        if lastSaveError != nil {
            _ = await enqueuePersist().result
            await drainQueuedPersists()
        }
    }

    /// Persists the current state, behind any queued persists, and throws if that write fails.
    public func persistNow() async throws {
        try await enqueuePersist().value
    }

    private func drainQueuedPersists() async {
        while let task = queuedPersists.values.first {
            _ = await task.result
        }
    }

    /// Turns the record into a tombstone (hidden from queries, kept dirty so it syncs).
    /// Deleting an unknown or already deleted id does nothing.
    public func delete<M: SyncableModel>(_: M.Type, id: UUID) async throws {
        guard let existing = records[id], existing.type == M.recordType, !existing.deleted else { return }
        var model = try existing.decode(M.self)
        model.deleted = true
        model.updatedAt = Timestamps.nextUpdate(previous: existing.updatedAt)
        store(try PlainRecord(model, deviceID: deviceID, keepingUnknownFieldsOf: existing))
        localChangeHandler?()
        try await enqueuePersist().value
    }

    private func apply<M: SyncableModel>(_ model: M) throws -> M {
        var stored = model
        stored.updatedAt = Timestamps.nextUpdate(previous: records[model.id]?.updatedAt)
        // Fields a newer app version wrote are kept (forward-compatible sync).
        store(try PlainRecord(stored, deviceID: deviceID, keepingUnknownFieldsOf: records[model.id]))
        localChangeHandler?()
        return stored
    }

    /// Starts a persist of the current state and tracks it until it finishes, for `flush()`.
    @discardableResult
    private func enqueuePersist() -> Task<Void, Error> {
        persistCounter += 1
        let key = persistCounter
        let task = Task { @MainActor in
            defer { queuedPersists[key] = nil }
            try await persist()
        }
        queuedPersists[key] = task
        return task
    }

    private func store(_ record: PlainRecord) {
        if records[record.id] == nil { order.append(record.id) }
        records[record.id] = record
        dirty.insert(record.id)
        revision += 1
    }

    /// Persists the current state. Writes are serialized FIFO: each call waits for the previous
    /// write to finish, then snapshots the state at write time, so the last write on disk is
    /// always the latest state and `lastSaveError` reflects the most recently completed write.
    private func persist() async throws {
        if persistInFlight {
            await withCheckedContinuation { persistWaiters.append($0) }
        } else {
            persistInFlight = true
        }
        defer {
            if persistWaiters.isEmpty {
                persistInFlight = false
            } else {
                persistWaiters.removeFirst().resume()
            }
        }
        let contents = VaultFileContents(deviceID: deviceID, syncState: syncState,
                                         records: order.compactMap { records[$0] }, dirty: dirty,
                                         mergeJoinLocalIDs: mergeJoinLocalIDs)
        do {
            try await persistence.save(contents)
            lastSaveError = nil
        } catch {
            lastSaveError = error
            throw error
        }
    }
}

// MARK: Sync store support (used by LocalVaultSyncStore and SyncCoordinator)

extension LocalVault {
    /// Dirty records in insertion order.
    func syncDirtyRecords() -> [PlainRecord] {
        order.compactMap { dirty.contains($0) ? records[$0] : nil }
    }

    func syncMarkClean(_ ids: [UUID: Date]) async throws {
        var changed = false
        for (id, updatedAt) in ids where dirty.contains(id) && records[id]?.updatedAt == updatedAt {
            dirty.remove(id)
            changed = true
        }
        if changed { try await enqueuePersist().value }
    }

    /// Stores each pulled record that wins `MergeRule` against the local copy, clean.
    func syncApply(_ incoming: [PlainRecord]) async throws {
        var changed = false
        for record in incoming {
            if let existing = records[record.id],
               !MergeRule.incomingWins((record.updatedAt, record.deviceID),
                                       over: (existing.updatedAt, existing.deviceID)) {
                continue
            }
            if records[record.id] == nil { order.append(record.id) }
            records[record.id] = record
            dirty.remove(record.id)
            changed = true
        }
        guard changed else { return }
        revision += 1
        try await enqueuePersist().value
    }

    func syncMarkAllDirty() async throws {
        dirty = Set(order)
        try await enqueuePersist().value
    }

    func syncRemoveAll() async throws {
        records = [:]
        order = []
        dirty = []
        mergeJoinLocalIDs = nil
        revision += 1
        try await enqueuePersist().value
    }

    var currentSyncState: SyncState { syncState }

    /// Forgets the vault this Mac synced with (disconnect); the write is queued, `flush()` waits for it.
    func syncResetState() {
        syncState = SyncState(vaultID: nil, lastSeq: 0)
        mergeJoinLocalIDs = nil
        enqueuePersist()
    }

    func syncSetState(_ state: SyncState) async throws {
        syncState = state
        try await enqueuePersist().value
    }

    /// Every stored record (tombstones included), in insertion order.
    var allRecords: [PlainRecord] { order.compactMap { records[$0] } }

    /// The ids of the records this Mac had before the pending merge join started. The first call
    /// of a join records (and persists) the current ids; later calls, including after a relaunch,
    /// return the same set until `applyJoinPlan` (or a replace join / disconnect) clears it, so
    /// records pulled by an interrupted attempt are never mistaken for local ones.
    func syncBeginMergeJoin() async throws -> Set<UUID> {
        if let ids = mergeJoinLocalIDs { return ids }
        let ids = Set(order)
        mergeJoinLocalIDs = ids
        try await enqueuePersist().value
        return ids
    }

    /// Forgets a pending merge join (a new vault was created or another server connected); the
    /// write is queued, `flush()` waits for it.
    func syncClearMergeJoin() {
        guard mergeJoinLocalIDs != nil else { return }
        mergeJoinLocalIDs = nil
        enqueuePersist()
    }

    /// Applies a join de-duplication plan: drops `plan.removedIDs` without tombstones and stores
    /// `plan.updated` as local, dirty edits (new `updatedAt`). Doesn't call `localChangeHandler`.
    /// Ends the pending merge join (clears the `syncBeginMergeJoin` marker) in the same write.
    ///
    /// Records outside `localIDs` that came from other devices are vault records pulled by this or
    /// an earlier, interrupted attempt; the join's `markAllDirty` flagged them, so they are marked
    /// clean again here and not re-uploaded. (Records this Mac wrote stay dirty.)
    func applyJoinPlan(_ plan: JoinDeduplicator.Plan, localIDs: Set<UUID>) async throws {
        let pulled = dirty.filter { !localIDs.contains($0) && records[$0].map { $0.deviceID != deviceID } == true }
        guard !plan.removedIDs.isEmpty || !plan.updated.isEmpty || !pulled.isEmpty else {
            if mergeJoinLocalIDs != nil {
                mergeJoinLocalIDs = nil
                try await enqueuePersist().value
            }
            return
        }
        dirty.subtract(pulled)
        for id in plan.removedIDs {
            records[id] = nil
            dirty.remove(id)
        }
        order.removeAll { plan.removedIDs.contains($0) }
        for var record in plan.updated where records[record.id] != nil {
            record.updatedAt = Timestamps.nextUpdate(previous: records[record.id]?.updatedAt)
            record.deviceID = deviceID
            record.payload = try JoinDeduplicator.restamp(record.payload, type: record.type,
                                                          updatedAt: record.updatedAt)
            store(record)
        }
        mergeJoinLocalIDs = nil
        revision += 1
        try await enqueuePersist().value
    }
}
