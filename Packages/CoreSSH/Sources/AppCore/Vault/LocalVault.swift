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
/// order and decoded on query. Every change marks the record dirty and is persisted; deletes
/// are tombstones.
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
            for record in contents.records where vault.records[record.id] == nil {
                vault.records[record.id] = record
                vault.order.append(record.id)
            }
            return vault
        }
        return LocalVault(persistence: persistence, deviceID: newDeviceID())
    }

    /// Non-deleted records of type `M`, in insertion order.
    public func all<M: SyncableModel>(_: M.Type) -> [M] {
        order.compactMap { id in
            guard let record = records[id], record.type == M.recordType, !record.deleted else { return nil }
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
        store(try PlainRecord(model, deviceID: deviceID))
        try await enqueuePersist().value
    }

    private func apply<M: SyncableModel>(_ model: M) throws -> M {
        var stored = model
        stored.updatedAt = Timestamps.nextUpdate(previous: records[model.id]?.updatedAt)
        store(try PlainRecord(stored, deviceID: deviceID))
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
                                         records: order.compactMap { records[$0] }, dirty: dirty)
        do {
            try await persistence.save(contents)
            lastSaveError = nil
        } catch {
            lastSaveError = error
            throw error
        }
    }
}
