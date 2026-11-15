import Foundation
import SyncCore

/// `LocalVault` as `SyncEngine`'s `SyncLocalStore`: every call hops to the main actor.
///
/// - `apply` keeps a pulled record only if it wins `MergeRule` against the local copy; kept records
///   are clean (not re-uploaded), bump `revision` and don't count as local changes. Pulled
///   tombstones hide their records.
/// - `markClean` clears a dirty flag only while the record's `updatedAt` is unchanged.
/// - `syncState` is persisted in the vault file.
public struct LocalVaultSyncStore: SyncLocalStore {
    public let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    public func dirtyRecords() async throws -> [PlainRecord] {
        await vault.syncDirtyRecords()
    }

    public func markClean(_ ids: [UUID: Date]) async throws {
        try await vault.syncMarkClean(ids)
    }

    public func apply(_ records: [PlainRecord]) async throws {
        try await vault.syncApply(records)
    }

    public func markAllDirty() async throws {
        try await vault.syncMarkAllDirty()
    }

    public func removeAll() async throws {
        try await vault.syncRemoveAll()
    }

    public var syncState: SyncState {
        get async { await vault.currentSyncState }
    }

    public func setSyncState(_ state: SyncState) async throws {
        try await vault.syncSetState(state)
    }
}
