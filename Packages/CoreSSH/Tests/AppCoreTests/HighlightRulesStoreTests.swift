import XCTest
import Observation
import CoreModels
import SyncCore
import SyncTestSupport
@testable import AppCore

@MainActor
final class HighlightRulesStoreTests: XCTestCase {
    private var vault: LocalVault!
    private var store: HighlightRulesStore!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
        store = HighlightRulesStore(vault: vault)
    }

    private func rule(_ pattern: String) -> HighlightRule {
        HighlightRule(pattern: pattern, color: HighlightPalette.defaultColor.hex)
    }

    func testEmptyUntilRulesAreAdded() async {
        XCTAssertEqual(store.rules, [])
        XCTAssertTrue(store.compiled.isEmpty)
        XCTAssertNil(vault.get(TerminalHighlightRules.self, id: TerminalHighlightRules.singletonID))
    }

    func testAddStoresOneSyncedRecord() async {
        let a = rule("prod")
        let b = rule("db")
        store.add(a)
        store.add(b)
        XCTAssertEqual(store.rules, [a, b])
        let record = vault.get(TerminalHighlightRules.self, id: TerminalHighlightRules.singletonID)
        XCTAssertEqual(record?.rules, [a, b])
        XCTAssertEqual(vault.syncDirtyRecords().map(\.id), [TerminalHighlightRules.singletonID])
        XCTAssertEqual(vault.syncDirtyRecords().first?.type, .aiSettings)
    }

    func testUpdateDeleteAndEnable() async {
        var a = rule("prod")
        let b = rule("db")
        store.add(a)
        store.add(b)
        a.pattern = "production"
        store.update(a)
        XCTAssertEqual(store.rules.map(\.pattern), ["production", "db"])
        store.setEnabled(false, id: b.id)
        XCTAssertEqual(store.rules.map(\.isEnabled), [true, false])
        store.delete(id: a.id)
        XCTAssertEqual(store.rules.map(\.pattern), ["db"])
    }

    func testUpdateOfARuleDeletedElsewhereAddsItBack() async {
        let a = rule("prod")
        store.update(a)
        XCTAssertEqual(store.rules, [a])
    }

    func testReorder() async {
        let a = rule("a"), b = rule("b"), c = rule("c")
        for r in [a, b, c] { store.add(r) }
        store.moveUp(id: c.id)
        XCTAssertEqual(store.rules.map(\.pattern), ["a", "c", "b"])
        store.moveUp(id: a.id) // already first
        store.moveDown(id: b.id) // already last
        XCTAssertEqual(store.rules.map(\.pattern), ["a", "c", "b"])
        store.moveDown(id: a.id)
        XCTAssertEqual(store.rules.map(\.pattern), ["c", "a", "b"])
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.rules.map(\.pattern), ["a", "b", "c"])
        store.move(fromOffsets: IndexSet([1, 2]), toOffset: 0)
        XCTAssertEqual(store.rules.map(\.pattern), ["b", "c", "a"])
    }

    func testCompiledFollowsRulesAndIsCached() async {
        store.add(rule("prod"))
        let first = store.compiled
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(store.compiled === first)
        store.add(rule("db"))
        XCTAssertFalse(store.compiled === first)
        XCTAssertEqual(store.compiled.rules.count, 2)
    }

    func testNewRuleTakesAnUnusedPaletteColour() async {
        XCTAssertEqual(store.makeNewRule().color, HighlightPalette.colors[0].color.hex)
        XCTAssertEqual(store.makeNewRule().pattern, "")
        store.add(rule("a"))
        XCTAssertEqual(store.makeNewRule().color, HighlightPalette.colors[1].color.hex)
    }

    func testWithoutVaultEditsAreIgnored() async {
        let detached = HighlightRulesStore()
        XCTAssertFalse(detached.isAvailable)
        detached.add(rule("prod"))
        XCTAssertEqual(detached.rules, [])
        detached.attach(vault)
        XCTAssertTrue(detached.isAvailable)
        detached.add(rule("prod"))
        XCTAssertEqual(detached.rules.map(\.pattern), ["prod"])
    }

    func testObserversSeeRulesPulledFromAnotherMac() async throws {
        let changed = RulesObservedFlag()
        _ = withObservationTracking { store.compiled } onChange: { changed.value = true }
        let remote = TerminalHighlightRules(rules: [rule("remote")], updatedAt: Date())
        try await vault.syncApply([PlainRecord(remote, deviceID: "dev-2")])
        XCTAssertTrue(changed.value)
        XCTAssertEqual(store.rules.map(\.pattern), ["remote"])
    }

    func testObserversSeeTheVaultArrive() async {
        let detached = HighlightRulesStore()
        let changed = RulesObservedFlag()
        _ = withObservationTracking { detached.rules } onChange: { changed.value = true }
        detached.attach(vault)
        XCTAssertTrue(changed.value)
    }

    /// The record shares the `.aiSettings` type tag so older apps don't fail on an unknown type; the
    /// two models must never decode as each other.
    func testSharesTheSettingsRecordTypeWithoutClashingWithAISettings() async throws {
        store.add(rule("prod"))
        let ai = AISettings(baseURL: "https://api.example", model: "m")
        vault.saveNow(ai)
        XCTAssertEqual(vault.all(AISettings.self).map(\.id), [ai.id])
        XCTAssertEqual(vault.get(TerminalHighlightRules.self, id: TerminalHighlightRules.singletonID)?.rules.count, 1)
        XCTAssertNil(vault.get(TerminalHighlightRules.self, id: ai.id))
        XCTAssertNil(vault.get(AISettings.self, id: TerminalHighlightRules.singletonID))
    }

    func testJoinDeduplicationLeavesTheRecordAlone() async throws {
        store.add(rule("prod"))
        let local = vault.allRecords
        let plan = JoinDeduplicator.plan(local: local, vault: [])
        XCTAssertEqual(plan, JoinDeduplicator.Plan())
    }

    // MARK: Two lists meeting (merge join, edits on two Macs before they sync)

    private func remoteRecord(_ rules: [HighlightRule], updatedAt: Date) throws -> PlainRecord {
        try PlainRecord(TerminalHighlightRules(rules: rules, updatedAt: updatedAt), deviceID: "dev-2")
    }

    func testPulledListIsUnitedWithAnUnsyncedLocalList() async throws {
        let local = rule("staging")
        store.add(local)
        let remote = [rule("prod"), rule("db")]
        // Older and newer than the local edit: either way neither Mac's rules are lost.
        for updatedAt in [Date(timeIntervalSince1970: 1_000), Date().addingTimeInterval(3_600)] {
            try await vault.syncApply([try remoteRecord(remote, updatedAt: updatedAt)])
            XCTAssertEqual(store.rules.map(\.pattern), ["prod", "db", "staging"], "vault order, then local-only rules")
            let stored = try XCTUnwrap(vault.syncDirtyRecords().first { $0.id == TerminalHighlightRules.singletonID },
                                       "the union is a local edit, uploaded by the next sync")
            XCTAssertEqual(stored.deviceID, "dev-1")
            XCTAssertGreaterThan(stored.updatedAt, updatedAt)
        }
    }

    func testPulledListReplacesACleanLocalList() async throws {
        store.add(rule("staging"))
        let local = try XCTUnwrap(vault.syncDirtyRecords().first)
        try await vault.syncMarkClean([local.id: local.updatedAt])
        try await vault.syncApply([try remoteRecord([rule("prod")], updatedAt: Date().addingTimeInterval(60))])
        XCTAssertEqual(store.rules.map(\.pattern), ["prod"], "a synced list is replaced as before (deletes stick)")
        XCTAssertTrue(vault.syncDirtyRecords().isEmpty)
    }

    func testOwnEchoIsNotUnited() async throws {
        let prod = rule("prod")
        store.add(prod)
        let pushed = try XCTUnwrap(vault.syncDirtyRecords().first)
        store.delete(id: prod.id)
        store.add(rule("db"))
        // The pull returns this Mac's own earlier upload: the newer local list stays as it is.
        try await vault.syncApply([pushed])
        XCTAssertEqual(store.rules.map(\.pattern), ["db"])
    }

    func testPulledSupersetIsTakenClean() async throws {
        let prod = rule("prod")
        store.add(prod)
        try await vault.syncApply([try remoteRecord([prod, rule("db")], updatedAt: Date().addingTimeInterval(60))])
        XCTAssertEqual(store.rules.map(\.pattern), ["prod", "db"])
        XCTAssertTrue(vault.syncDirtyRecords().isEmpty, "nothing of this Mac's is missing, so nothing to upload")
    }

    // MARK: A list this version can't read

    func testUnreadableListIsReadOnlyAndNeverOverwritten() async throws {
        let json = #"{"id":"6C1B2E1A-0B5D-4E0C-9D6A-48494C495445","updatedAt":1793000000000,"deleted":false,"rules":{"v":2}}"#
        let record = PlainRecord(id: TerminalHighlightRules.singletonID, type: .aiSettings,
                                 updatedAt: Date(timeIntervalSince1970: 1_793_000_000), deleted: false,
                                 deviceID: "dev-2", payload: Data(json.utf8))
        try await vault.syncApply([record])
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(store.rules, [])
        store.add(rule("prod"))
        XCTAssertEqual(vault.allRecords.first { $0.id == TerminalHighlightRules.singletonID }?.payload, Data(json.utf8),
                       "the newer version's list is kept")
        XCTAssertTrue(vault.syncDirtyRecords().isEmpty)
    }

    func testReadableListIsNotReadOnly() async {
        XCTAssertFalse(store.isReadOnly)
        store.add(rule("prod"))
        XCTAssertFalse(store.isReadOnly)
    }

    /// End to end through the sync engine: rules made on one Mac arrive, decrypted, on the other,
    /// and an edit there comes back.
    func testRulesSyncBetweenTwoMacs() async throws {
        let transport = InMemoryTransport()
        let macA = vault!
        let macB = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-2" })
        let engineA = SyncEngine(transport: transport, store: LocalVaultSyncStore(vault: macA), deviceID: "dev-1",
                                 iterations: 1_000)
        let engineB = SyncEngine(transport: transport, store: LocalVaultSyncStore(vault: macB), deviceID: "dev-2",
                                 iterations: 1_000)
        _ = try await engineA.createVault(passphrase: "correct horse battery")
        _ = try await engineB.join(passphrase: "correct horse battery", mode: .merge)

        var prod = rule("prod")
        prod.isBold = true
        store.add(prod)
        _ = try await engineA.sync()
        _ = try await engineB.sync()
        let storeB = HighlightRulesStore(vault: macB)
        XCTAssertEqual(storeB.rules, [prod])

        storeB.setEnabled(false, id: prod.id)
        _ = try await engineB.sync()
        _ = try await engineA.sync()
        XCTAssertEqual(store.rules.map(\.isEnabled), [false])
    }
}

/// Set from an observation's onChange (called synchronously when the observed value changes).
private final class RulesObservedFlag: @unchecked Sendable {
    var value = false
}
