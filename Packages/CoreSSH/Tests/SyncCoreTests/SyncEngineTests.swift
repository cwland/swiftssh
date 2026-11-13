import XCTest
import Crypto
import CoreModels
@testable import SyncCore
import SyncTestSupport

private typealias Host = CoreModels.Host

final class SyncEngineTests: XCTestCase {
    private let iterations = 1_000
    private let passphrase = "correct horse battery staple"

    private struct Device {
        let store: InMemoryStore
        let engine: SyncEngine
    }

    private func device(_ id: String, _ transport: InMemoryTransport) -> Device {
        let store = InMemoryStore(deviceID: id)
        return Device(store: store,
                      engine: SyncEngine(transport: transport, store: store, deviceID: id, iterations: iterations))
    }

    private func host(_ label: String) -> Host {
        Host(label: label, address: "\(label).lan", updatedAt: Timestamps.nextUpdate(previous: nil))
    }

    func testCreateVaultThenSyncPushesLocalRecords() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        try await a.store.insert(host("nas"))
        try await a.store.insert(host("pi"))

        _ = try await a.engine.createVault(passphrase: passphrase)
        let report = try await a.engine.sync()

        XCTAssertEqual(report.pushed, 2)
        let stored = await transport.storedRecords
        XCTAssertEqual(stored.count, 2)
        for record in stored {
            XCTAssertFalse(String(decoding: record.ciphertext, as: UTF8.self).contains(".lan"))
        }
        let dirty = await a.store.dirtyCount
        XCTAssertEqual(dirty, 0)
        let vaultID = await transport.vault?.vaultID
        let state = await a.store.syncState
        XCTAssertEqual(state.vaultID, vaultID)
        XCTAssertEqual(state.lastSeq, 2)
    }

    func testCreateVaultWhenOneExistsThrows() async throws {
        let transport = InMemoryTransport()
        _ = try await device("mac-a", transport).engine.createVault(passphrase: passphrase)
        do {
            _ = try await device("mac-b", transport).engine.createVault(passphrase: passphrase)
            XCTFail("expected .vaultAlreadyExists")
        } catch {
            XCTAssertEqual(error as? SyncError, .vaultAlreadyExists)
        }
    }

    func testSecondDeviceJoinsAndPullsRecords() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let nas = host("nas")
        let snippet = Snippet(name: "update", script: "apt update", updatedAt: Timestamps.nextUpdate(previous: nil))
        try await a.store.insert(nas)
        try await a.store.insert(snippet)
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()

        let b = device("mac-b", transport)
        let exists = try await b.engine.vaultExists()
        XCTAssertTrue(exists)
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        let report = try await b.engine.sync()

        XCTAssertEqual(report.pulled, 2)
        let pulledHost = try await b.store.model(Host.self, id: nas.id)
        let pulledSnippet = try await b.store.model(Snippet.self, id: snippet.id)
        XCTAssertEqual(pulledHost, nas)
        XCTAssertEqual(pulledSnippet, snippet)
        let state = await b.store.syncState
        XCTAssertEqual(state.lastSeq, 2)
    }

    func testVaultExistsIsFalseOnEmptyServer() async throws {
        let exists = try await device("mac-a", InMemoryTransport()).engine.vaultExists()
        XCTAssertFalse(exists)
    }

    func testJoinWithoutVaultThrowsNoVault() async throws {
        do {
            _ = try await device("mac-a", InMemoryTransport()).engine.join(passphrase: passphrase, mode: .merge)
            XCTFail("expected .noVault")
        } catch {
            XCTAssertEqual(error as? SyncError, .noVault)
        }
    }

    func testJoinWithWrongPassphraseThrowsAndTouchesNothing() async throws {
        let transport = InMemoryTransport()
        _ = try await device("mac-a", transport).engine.createVault(passphrase: passphrase)
        let b = device("mac-b", transport)
        let local = host("laptop")
        try await b.store.insert(local)
        try await b.store.markClean([local.id: local.updatedAt])

        do {
            _ = try await b.engine.join(passphrase: "wrong", mode: .replace)
            XCTFail("expected .wrongPassphrase")
        } catch {
            XCTAssertEqual(error as? SyncError, .wrongPassphrase)
        }

        let kept = try await b.store.model(Host.self, id: local.id)
        XCTAssertEqual(kept, local)
        let dirty = await b.store.isDirty(local.id)
        XCTAssertFalse(dirty)
        let state = await b.store.syncState
        XCTAssertEqual(state, SyncState(vaultID: nil, lastSeq: 0))
        let upserts = await transport.upsertCallCount
        XCTAssertEqual(upserts, 0)
        do {
            _ = try await b.engine.sync()
            XCTFail("expected .locked")
        } catch {
            XCTAssertEqual(error as? SyncError, .locked)
        }
    }

    func testJoinReplaceDiscardsLocalData() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let nas = host("nas")
        try await a.store.insert(nas)
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()

        let b = device("mac-b", transport)
        let local = host("laptop")
        try await b.store.insert(local)
        _ = try await b.engine.join(passphrase: passphrase, mode: .replace)
        let report = try await b.engine.sync()

        XCTAssertEqual(report.pushed, 0)
        let gone = try await b.store.model(Host.self, id: local.id)
        XCTAssertNil(gone)
        let pulled = try await b.store.model(Host.self, id: nas.id)
        XCTAssertEqual(pulled, nas)
        let stored = await transport.storedRecords.map(\.id)
        XCTAssertEqual(stored, [nas.id])
    }

    func testJoinMergeUploadsLocalData() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let nas = host("nas")
        try await a.store.insert(nas)
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()

        let b = device("mac-b", transport)
        let local = host("laptop")
        try await b.store.insert(local)
        try await b.store.markClean([local.id: local.updatedAt]) // merge must re-dirty it
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        let report = try await b.engine.sync()
        XCTAssertEqual(report.pushed, 1)

        _ = try await a.engine.sync()
        let arrived = try await a.store.model(Host.self, id: local.id)
        XCTAssertEqual(arrived, local)
        let kept = try await b.store.model(Host.self, id: nas.id)
        XCTAssertEqual(kept, nas)
    }

    func testEditOnOneDeviceReachesTheOther() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let nas = host("nas")
        try await a.store.insert(nas)
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()
        let b = device("mac-b", transport)
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        _ = try await b.engine.sync()

        let edited = try await a.store.edit(Host.self, id: nas.id) { $0.address = "10.0.0.5" }
        let pushed = try await a.engine.sync().pushed
        XCTAssertEqual(pushed, 1)
        let report = try await b.engine.sync()

        XCTAssertEqual(report.pulled, 1)
        let onB = try await b.store.model(Host.self, id: nas.id)
        XCTAssertEqual(onB, edited)
        XCTAssertEqual(onB?.address, "10.0.0.5")
    }

    func testInterruptedPushLeavesRecordsDirty() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let nas = host("nas")
        try await a.store.insert(nas)
        _ = try await a.engine.createVault(passphrase: passphrase)

        await transport.failNextUpsert()
        do {
            _ = try await a.engine.sync()
            XCTFail("expected the injected failure")
        } catch {
            XCTAssertEqual(error as? InMemoryTransportError, .injectedFailure)
        }
        let stillDirty = await a.store.isDirty(nas.id)
        XCTAssertTrue(stillDirty)

        let report = try await a.engine.sync()
        XCTAssertEqual(report.pushed, 1)
        let dirty = await a.store.isDirty(nas.id)
        XCTAssertFalse(dirty)
        let stored = await transport.storedRecords
        XCTAssertEqual(stored.map(\.id), [nas.id])
    }

    func testRecordEditedDuringPushStaysDirty() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let nas = host("nas")
        try await a.store.insert(nas)
        _ = try await a.engine.createVault(passphrase: passphrase)

        let store = a.store
        await store.onNextDirtyRecords {
            try await store.edit(Host.self, id: nas.id) { $0.label = "nas-renamed" }
        }
        _ = try await a.engine.sync()

        let dirty = await a.store.isDirty(nas.id)
        XCTAssertTrue(dirty)
        let local = try await a.store.model(Host.self, id: nas.id)
        XCTAssertEqual(local?.label, "nas-renamed")

        let report = try await a.engine.sync()
        XCTAssertEqual(report.pushed, 1)
        let cleaned = await a.store.isDirty(nas.id)
        XCTAssertFalse(cleaned)
    }

    func testVaultChangedIsDetected() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        _ = try await a.engine.createVault(passphrase: passphrase)
        try await a.store.insert(host("nas"))

        await transport.replaceVault(VaultMetadata(vaultID: UUID(), salt: VaultCrypto.randomSalt(),
                                                   iterations: iterations, wrappedKey: Data(repeating: 1, count: 60)))
        do {
            _ = try await a.engine.sync()
            XCTFail("expected .vaultChanged")
        } catch {
            XCTAssertEqual(error as? SyncError, .vaultChanged)
        }
        let upserts = await transport.upsertCallCount
        XCTAssertEqual(upserts, 0)

        await transport.replaceVault(nil)
        do {
            _ = try await a.engine.sync()
            XCTFail("expected .vaultChanged")
        } catch {
            XCTAssertEqual(error as? SyncError, .vaultChanged)
        }
        let after = await transport.upsertCallCount
        XCTAssertEqual(after, 0)
    }

    func testSyncWhileLockedThrows() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let key = try await a.engine.createVault(passphrase: passphrase)

        let fresh = SyncEngine(transport: transport, store: a.store, deviceID: "mac-a", iterations: iterations)
        do {
            _ = try await fresh.sync()
            XCTFail("expected .locked")
        } catch {
            XCTAssertEqual(error as? SyncError, .locked)
        }
        await fresh.unlock(with: key)
        let report = try await fresh.sync()
        XCTAssertEqual(report, SyncReport(pushed: 0, pulled: 0))
    }

    func testChangePassphraseKeepsDataReadable() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let nas = host("nas")
        try await a.store.insert(nas)
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()
        let vaultID = await transport.vault?.vaultID

        do {
            try await a.engine.changePassphrase(old: "not it", new: "new phrase")
            XCTFail("expected .wrongPassphrase")
        } catch {
            XCTAssertEqual(error as? SyncError, .wrongPassphrase)
        }

        let oldSalt = await transport.vault?.salt
        try await a.engine.changePassphrase(old: passphrase, new: "new phrase")
        let vault = await transport.vault
        XCTAssertEqual(vault?.vaultID, vaultID)
        XCTAssertNotEqual(vault?.salt, oldSalt)

        // The engine keeps working with the same vault key.
        let edited = try await a.store.edit(Host.self, id: nas.id) { $0.port = 2222 }
        let pushed = try await a.engine.sync().pushed
        XCTAssertEqual(pushed, 1)

        let c = device("mac-c", transport)
        _ = try await c.engine.join(passphrase: "new phrase", mode: .merge)
        _ = try await c.engine.sync()
        let onC = try await c.store.model(Host.self, id: nas.id)
        XCTAssertEqual(onC, edited)

        do {
            _ = try await device("mac-d", transport).engine.join(passphrase: passphrase, mode: .merge)
            XCTFail("expected .wrongPassphrase")
        } catch {
            XCTAssertEqual(error as? SyncError, .wrongPassphrase)
        }
    }

    func testPullPagesUntilDone() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        for i in 0..<1_200 { try await a.store.insert(host("h\(i)")) }
        _ = try await a.engine.createVault(passphrase: passphrase)
        let pushed = try await a.engine.sync().pushed
        XCTAssertEqual(pushed, 1_200)
        let upserts = await transport.upsertCallCount
        XCTAssertEqual(upserts, 3) // batches of 500, 500, 200

        let b = device("mac-b", transport)
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        let fetchesBefore = await transport.fetchCallCount
        let report = try await b.engine.sync()

        XCTAssertEqual(report.pulled, 1_200)
        let fetches = await transport.fetchCallCount - fetchesBefore
        XCTAssertEqual(fetches, 3)
        let count = await b.store.count
        XCTAssertEqual(count, 1_200)
        let maxSeq = await transport.storedRecords.compactMap(\.seq).max()
        let state = await b.store.syncState
        XCTAssertEqual(state.lastSeq, maxSeq)
        XCTAssertEqual(state.lastSeq, 1_200)
    }
}
