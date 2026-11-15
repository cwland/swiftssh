import XCTest
import CoreModels
import SyncCore
@testable import AppCore

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

@MainActor
final class LocalVaultSyncStoreTests: XCTestCase {
    private func open(_ p: InMemoryVaultPersistence = InMemoryVaultPersistence()) async throws -> LocalVault {
        try await LocalVault.open(persistence: p, newDeviceID: { "mac-a" })
    }

    private func remote<M: SyncableModel>(_ model: M, device: String = "mac-b") throws -> PlainRecord {
        try PlainRecord(model, deviceID: device)
    }

    func testMergeJoinMarkerPersistsIsReusedAndClearedByThePlan() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let a = try await vault.save(Host(label: "a", address: "a.lan"))
        let first = try await vault.syncBeginMergeJoin()
        XCTAssertEqual(first, [a.id])
        let pulled = try remote(Host(label: "v", address: "v.lan"))
        try await LocalVaultSyncStore(vault: vault).apply([pulled])

        let reopened = try await open(p)
        let again = try await reopened.syncBeginMergeJoin()
        XCTAssertEqual(again, [a.id], "a retry after a relaunch reuses the pre-join ids")
        try await reopened.applyJoinPlan(JoinDeduplicator.Plan(removedIDs: [], idMap: [:], updated: []))
        let marker = await p.contents?.mergeJoinLocalIDs
        XCTAssertNil(marker)
        let fresh = try await reopened.syncBeginMergeJoin()
        XCTAssertEqual(fresh, [a.id, pulled.id])
    }

    func testVaultFileWithoutMergeJoinMarkerStillDecodes() async throws {
        let old = VaultFileContents(deviceID: "mac-a")
        var json = try JSONSerialization.jsonObject(with: CoreJSON.encoder.encode(old)) as! [String: Any]
        json["mergeJoinLocalIDs"] = nil
        let decoded = try CoreJSON.decoder.decode(VaultFileContents.self,
                                                  from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.mergeJoinLocalIDs)
        XCTAssertEqual(decoded.deviceID, "mac-a")
    }

    func testDirtyRecordsAreTheLocalChangesInOrder() async throws {
        let vault = try await open()
        let store = LocalVaultSyncStore(vault: vault)
        let a = try await vault.save(Host(label: "a", address: "a.lan"))
        let b = try await vault.save(Host(label: "b", address: "b.lan"))
        let dirty = try await store.dirtyRecords()
        XCTAssertEqual(dirty.map(\.id), [a.id, b.id])
        XCTAssertEqual(dirty.first?.deviceID, "mac-a")
    }

    func testMarkCleanOnlyWhenUpdatedAtStillMatchesAndPersists() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let store = LocalVaultSyncStore(vault: vault)
        let a = try await vault.save(Host(label: "a", address: "a.lan"))
        let b = try await vault.save(Host(label: "b", address: "b.lan"))
        let staleB = b.updatedAt.addingTimeInterval(-1)
        try await store.markClean([a.id: a.updatedAt, b.id: staleB])
        let dirty = try await store.dirtyRecords()
        XCTAssertEqual(dirty.map(\.id), [b.id])
        let contents = await p.contents
        XCTAssertEqual(contents?.dirty, [b.id])
    }

    func testApplyAddsCleanRecordsBumpsRevisionWithoutLocalChange() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let store = LocalVaultSyncStore(vault: vault)
        var localChanges = 0
        vault.localChangeHandler = { localChanges += 1 }
        let before = vault.revision
        let host = Host(label: "nas", address: "nas.lan", updatedAt: Date(timeIntervalSince1970: 1_000))

        try await store.apply([try remote(host)])

        XCTAssertEqual(vault.get(Host.self, id: host.id), host)
        XCTAssertGreaterThan(vault.revision, before)
        XCTAssertEqual(localChanges, 0)
        let dirty = try await store.dirtyRecords()
        XCTAssertTrue(dirty.isEmpty)
        let contents = await p.contents
        XCTAssertEqual(contents?.records.map(\.id), [host.id])
        XCTAssertEqual(contents?.dirty, [])
    }

    func testApplyUsesMergeRuleAgainstLocalCopies() async throws {
        let vault = try await open()
        let store = LocalVaultSyncStore(vault: vault)
        let local = try await vault.save(Host(label: "local", address: "a.lan"))

        var older = local
        older.label = "older"
        older.updatedAt = local.updatedAt.addingTimeInterval(-10)
        try await store.apply([try remote(older)])
        XCTAssertEqual(vault.get(Host.self, id: local.id)?.label, "local")
        let stillDirty = try await store.dirtyRecords()
        XCTAssertEqual(stillDirty.map(\.id), [local.id])

        var newer = local
        newer.label = "newer"
        newer.updatedAt = local.updatedAt.addingTimeInterval(10)
        try await store.apply([try remote(newer)])
        XCTAssertEqual(vault.get(Host.self, id: local.id)?.label, "newer")
        let dirty = try await store.dirtyRecords()
        XCTAssertTrue(dirty.isEmpty, "the winning pulled copy replaced the local edit")
    }

    func testPulledTombstoneHidesRecord() async throws {
        let vault = try await open()
        let store = LocalVaultSyncStore(vault: vault)
        let local = try await vault.save(Host(label: "nas", address: "nas.lan"))
        try await store.markClean([local.id: local.updatedAt])
        var tombstone = local
        tombstone.deleted = true
        tombstone.updatedAt = local.updatedAt.addingTimeInterval(5)
        try await store.apply([try remote(tombstone)])
        XCTAssertNil(vault.get(Host.self, id: local.id))
        XCTAssertTrue(vault.all(Host.self).isEmpty)
    }

    func testLocalSavesAndDeletesCallTheLocalChangeHandler() async throws {
        let vault = try await open()
        var localChanges = 0
        vault.localChangeHandler = { localChanges += 1 }
        let host = try await vault.save(Host(label: "nas", address: "nas.lan"))
        vault.saveNow(Snippet(name: "s", script: "ls"))
        try await vault.delete(Host.self, id: host.id)
        XCTAssertEqual(localChanges, 3)
    }

    func testMarkAllDirtyIncludesTombstonesAndRemoveAllEmpties() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let store = LocalVaultSyncStore(vault: vault)
        let a = try await vault.save(Host(label: "a", address: "a.lan"))
        let b = try await vault.save(Host(label: "b", address: "b.lan"))
        try await vault.delete(Host.self, id: b.id)
        try await store.markClean([a.id: a.updatedAt])
        let bRecord = try await store.dirtyRecords()
        try await store.markClean(Dictionary(uniqueKeysWithValues: bRecord.map { ($0.id, $0.updatedAt) }))

        try await store.markAllDirty()
        let dirty = try await store.dirtyRecords()
        XCTAssertEqual(Set(dirty.map(\.id)), [a.id, b.id])

        let before = vault.revision
        try await store.removeAll()
        let afterRemove = try await store.dirtyRecords()
        XCTAssertTrue(afterRemove.isEmpty)
        XCTAssertTrue(vault.all(Host.self).isEmpty)
        XCTAssertGreaterThan(vault.revision, before)
        let contents = await p.contents
        XCTAssertEqual(contents?.records, [])
    }

    func testSyncStateIsPersistedWithTheVault() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let store = LocalVaultSyncStore(vault: vault)
        let state = SyncState(vaultID: UUID(), lastSeq: 42)
        try await store.setSyncState(state)
        let current = await store.syncState
        XCTAssertEqual(current, state)
        let reopened = try await LocalVault.open(persistence: p)
        let reopenedState = await LocalVaultSyncStore(vault: reopened).syncState
        XCTAssertEqual(reopenedState, state)
    }

    /// Local-only settings (OS icons, connection, 1Password, badges) are not vault records.
    func testOnlyVaultModelsAreSyncRecordTypes() async {
        XCTAssertEqual(Set(SyncRecordType.allCases),
                       [.host, .hostGroup, .identity, .sshKey, .snippet, .knownHost, .connectionLog,
                        .shellHistory, .aiSettings])
    }
}
