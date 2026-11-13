import Foundation
import CoreModels
import SyncCore

public enum InMemoryStoreError: Error, Equatable {
    case notFound(UUID)
}

/// An in-memory `SyncLocalStore` standing in for the app's store.
///
/// - Local writes (`insert`, `edit`) stamp this store's `deviceID` and mark the record dirty.
/// - `apply` uses `MergeRule`: an incoming record replaces the local one only if it wins, and
///   the replaced record is clean afterwards. A losing incoming record leaves the local one as is.
/// - `markClean` clears the dirty flag only when the stored `updatedAt` still equals the given one.
///
/// Test hook: `onNextDirtyRecords(_:)` runs a closure right after the next `dirtyRecords()`
/// snapshot is taken, e.g. to simulate an edit made while a push is in flight.
public actor InMemoryStore: SyncLocalStore {
    private struct Entry {
        var record: PlainRecord
        var dirty: Bool
    }

    public let deviceID: String
    private var entries: [UUID: Entry] = [:]
    private var state = SyncState(vaultID: nil, lastSeq: 0)
    private var dirtyRecordsHook: (@Sendable () async throws -> Void)?

    public init(deviceID: String) {
        self.deviceID = deviceID
    }

    // MARK: Helpers for tests

    /// Inserts (or overwrites) `model` as a local, dirty write from this device.
    public func insert<M: SyncableModel>(_ model: M) throws {
        entries[model.id] = Entry(record: try PlainRecord(model, deviceID: deviceID), dirty: true)
    }

    /// Edits a stored model locally: applies `change`, bumps `updatedAt` with
    /// `Timestamps.nextUpdate`, stamps this device and marks it dirty. Returns the edited model.
    @discardableResult
    public func edit<M: SyncableModel>(_ type: M.Type, id: UUID, _ change: @Sendable (inout M) -> Void) throws -> M {
        guard var model = try model(type, id: id) else {
            throw InMemoryStoreError.notFound(id)
        }
        change(&model)
        model.updatedAt = Timestamps.nextUpdate(previous: model.updatedAt)
        try insert(model)
        return model
    }

    /// The stored model with `id`, decoded as `M`, or nil.
    public func model<M: SyncableModel>(_ type: M.Type, id: UUID) throws -> M? {
        guard let entry = entries[id], entry.record.type == M.recordType else { return nil }
        return try entry.record.decode(M.self)
    }

    /// All stored models of type `M` (tombstones included), in no particular order.
    public func models<M: SyncableModel>(_ type: M.Type) throws -> [M] {
        try entries.values.filter { $0.record.type == M.recordType }.map { try $0.record.decode(M.self) }
    }

    public func record(id: UUID) -> PlainRecord? {
        entries[id]?.record
    }

    public func isDirty(_ id: UUID) -> Bool {
        entries[id]?.dirty ?? false
    }

    public var count: Int { entries.count }

    public var dirtyCount: Int { entries.values.filter(\.dirty).count }

    /// Runs `body` once, right after the next `dirtyRecords()` snapshot is taken.
    public func onNextDirtyRecords(_ body: @escaping @Sendable () async throws -> Void) {
        dirtyRecordsHook = body
    }

    // MARK: SyncLocalStore

    public func dirtyRecords() async throws -> [PlainRecord] {
        let snapshot = entries.values.filter(\.dirty).map(\.record)
        if let hook = dirtyRecordsHook {
            dirtyRecordsHook = nil
            try await hook()
        }
        return snapshot
    }

    public func markClean(_ ids: [UUID: Date]) async throws {
        for (id, updatedAt) in ids where entries[id]?.record.updatedAt == updatedAt {
            entries[id]?.dirty = false
        }
    }

    public func apply(_ records: [PlainRecord]) async throws {
        for incoming in records {
            if let existing = entries[incoming.id]?.record,
               !MergeRule.incomingWins((incoming.updatedAt, incoming.deviceID),
                                       over: (existing.updatedAt, existing.deviceID)) {
                continue
            }
            entries[incoming.id] = Entry(record: incoming, dirty: false)
        }
    }

    public func markAllDirty() async throws {
        for id in entries.keys { entries[id]?.dirty = true }
    }

    public func removeAll() async throws {
        entries = [:]
    }

    public var syncState: SyncState { state }

    public func setSyncState(_ newState: SyncState) async throws {
        state = newState
    }
}
