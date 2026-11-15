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
        let createdKey: VaultKey = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()

        let b = device("mac-b", transport)
        let exists = try await b.engine.vaultExists()
        XCTAssertTrue(exists)
        let joinedKey: VaultKey = try await b.engine.join(passphrase: passphrase, mode: .merge)
        XCTAssertEqual(joinedKey, createdKey)
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

    func testRecreateVaultAfterWipeReuploadsEverything() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let b = device("mac-b", transport)
        let hosts = [host("nas"), host("pi"), host("router")]
        for h in hosts { try await a.store.insert(h) }
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        _ = try await b.engine.sync()
        for d in [a, b] {
            let dirty = await d.store.dirtyCount
            XCTAssertEqual(dirty, 0)
            let state = await d.store.syncState
            XCTAssertEqual(state.lastSeq, 3)
        }

        await transport.replaceVault(nil) // server wiped and rebuilt empty
        do {
            _ = try await a.engine.sync()
            XCTFail("expected .vaultChanged")
        } catch {
            XCTAssertEqual(error as? SyncError, .vaultChanged)
        }

        _ = try await a.engine.createVault(passphrase: "new vault phrase")
        let reportA = try await a.engine.sync()
        XCTAssertEqual(reportA.pushed, 3)
        let onServer = await transport.storedRecords.map(\.id)
        XCTAssertEqual(Set(onServer), Set(hosts.map(\.id)))

        let fetchedFrom = SinceRecorder()
        await transport.onFetch { since in await fetchedFrom.record(since) }
        _ = try await b.engine.join(passphrase: "new vault phrase", mode: .merge)
        let reportB = try await b.engine.sync()
        let firstSince = await fetchedFrom.values.first
        XCTAssertEqual(firstSince, 0)
        XCTAssertEqual(reportB.pulled, 3)
        let newVaultID = await transport.vault?.vaultID
        let stateB = await b.store.syncState
        XCTAssertEqual(stateB, SyncState(vaultID: newVaultID, lastSeq: 3))
        for h in hosts {
            let onB = try await b.store.model(Host.self, id: h.id)
            XCTAssertEqual(onB, h)
        }
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

    func testConcurrentSyncCallsDoNotDoublePushOrRegressLastSeq() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        for label in ["nas", "pi", "router"] { try await a.store.insert(host(label)) }
        _ = try await a.engine.createVault(passphrase: passphrase)

        let held = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await transport.onNextUpsert {
            held.continuation.yield()
            for await _ in release.stream { break }
        }
        let engine = a.engine
        let firstTask = Task { try await engine.sync() }
        var heldIterator = held.stream.makeAsyncIterator()
        _ = await heldIterator.next() // first sync is mid-push
        let secondTask = Task { try await engine.sync() }
        try await Task.sleep(nanoseconds: 50_000_000) // let the second sync run if it could
        release.continuation.yield()
        let r1 = try await firstTask.value
        let r2 = try await secondTask.value

        XCTAssertEqual(r1.pushed + r2.pushed, 3)
        let upserts = await transport.upsertCallCount
        XCTAssertEqual(upserts, 1)
        let seqs = await a.store.syncStateHistory.map(\.lastSeq)
        XCTAssertEqual(seqs, seqs.sorted(), "lastSeq went backwards: \(seqs)")
        let state = await a.store.syncState
        XCTAssertEqual(state.lastSeq, 3)
    }

    func testJoinDuringSyncIsSerialized() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        for i in 0..<1_200 { try await a.store.insert(host("h\(i)")) }
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()

        let b = device("mac-b", transport)
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        let held = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await transport.onFetch { since in
            guard since == 500 else { return } // hold B's second page
            await transport.onFetch(nil)
            held.continuation.yield()
            for await _ in release.stream { break }
        }

        let engine = b.engine
        let passphrase = passphrase
        let syncTask = Task { try await engine.sync() }
        var heldIterator = held.stream.makeAsyncIterator()
        _ = await heldIterator.next()
        let joinTask = Task { try await engine.join(passphrase: passphrase, mode: .replace) }
        try await Task.sleep(nanoseconds: 50_000_000) // let the join run if it could
        release.continuation.yield()
        _ = try await syncTask.value
        _ = try await joinTask.value

        // Seqs are 1...1_200, one per record: the store must hold exactly the records up to lastSeq.
        let state = await b.store.syncState
        let count = await b.store.count
        XCTAssertEqual(count, Int(state.lastSeq))
        _ = try await b.engine.sync()
        let finalCount = await b.store.count
        XCTAssertEqual(finalCount, 1_200)
    }

    func testTamperedPulledRecordStopsSyncWithoutAdvancing() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        for label in ["nas", "pi", "router"] { try await a.store.insert(host(label)) }
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()
        let victim = await transport.storedRecords[1].id
        await transport.corruptCiphertext(of: victim)

        let b = device("mac-b", transport)
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        do {
            _ = try await b.engine.sync()
            XCTFail("expected .tamperedRecord")
        } catch {
            XCTAssertEqual(error as? SyncError, .tamperedRecord(victim))
        }
        let count = await b.store.count
        XCTAssertEqual(count, 0)
        let state = await b.store.syncState
        XCTAssertEqual(state.lastSeq, 0)
    }

    func testServerAlteredRecordMetadataIsReportedAsTampered() async throws {
        let alterations: [(String, @Sendable (inout EncryptedRecord) -> Void)] = [
            ("deleted flipped", { $0.deleted.toggle() }),
            ("updatedAt bumped", { $0.updatedAt = $0.updatedAt.addingTimeInterval(60) }),
            ("deviceID changed", { $0.deviceID = "zz-server" }),
        ]
        for (name, alter) in alterations {
            let transport = InMemoryTransport()
            let a = device("mac-a", transport)
            for label in ["nas", "pi"] { try await a.store.insert(host(label)) }
            _ = try await a.engine.createVault(passphrase: passphrase)
            _ = try await a.engine.sync()
            let victim = await transport.storedRecords[0].id
            await transport.mutateStoredRecord(victim, alter)

            let b = device("mac-b", transport)
            _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
            do {
                _ = try await b.engine.sync()
                XCTFail("expected .tamperedRecord when \(name)")
            } catch {
                XCTAssertEqual(error as? SyncError, .tamperedRecord(victim), name)
            }
            let count = await b.store.count
            XCTAssertEqual(count, 0, name)
        }
    }

    func testRestoredServerBackupTriggersFullResync() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let b = device("mac-b", transport)
        let nas = host("nas"), pi = host("pi"), router = host("router")
        try await a.store.insert(nas)
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        _ = try await b.engine.sync()
        let backup = await transport.snapshot() // holds only nas (seq 1)

        try await a.store.insert(pi)
        _ = try await a.engine.sync()        // pi: seq 2, A at lastSeq 2
        try await b.store.insert(router)
        _ = try await b.engine.sync()        // router: seq 3, B at lastSeq 3
        await transport.restore(backup)      // same vaultID, pi and router lost

        let reportA = try await a.engine.sync()
        XCTAssertEqual(reportA.pushed, 2)    // nas + pi, re-sent after the rewind
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()

        let expected = Set([nas.id, pi.id, router.id])
        let onServer = await transport.storedRecords.map(\.id)
        XCTAssertEqual(Set(onServer), expected)
        for (name, d) in [("A", a), ("B", b)] {
            for model in [nas, pi, router] {
                let local = try await d.store.model(Host.self, id: model.id)
                XCTAssertEqual(local, model, "\(name) is missing \(model.label)")
            }
            let dirty = await d.store.dirtyCount
            XCTAssertEqual(dirty, 0)
            let state = await d.store.syncState
            XCTAssertEqual(state.lastSeq, 3)
        }
    }

    func testOutOfRangeVaultIterationsAreRejectedBeforeDeriving() async throws {
        for bad in [0, -1, 999, 10_000_001, Int.max] {
            let transport = InMemoryTransport()
            let a = device("mac-a", transport)
            _ = try await a.engine.createVault(passphrase: passphrase)
            let current = await transport.vault
            var metadata = try XCTUnwrap(current)
            metadata.iterations = bad
            await transport.replaceVault(metadata, clearRecords: false)

            do {
                _ = try await device("mac-b", transport).engine.join(passphrase: passphrase, mode: .merge)
                XCTFail("expected .invalidVaultMetadata for join with \(bad) iterations")
            } catch {
                XCTAssertEqual(error as? SyncError, .invalidVaultMetadata, "join, \(bad)")
            }
            do {
                try await a.engine.changePassphrase(old: passphrase, new: "other")
                XCTFail("expected .invalidVaultMetadata for changePassphrase with \(bad) iterations")
            } catch {
                XCTAssertEqual(error as? SyncError, .invalidVaultMetadata, "changePassphrase, \(bad)")
            }
        }
    }

    func testInconsistentPagesThrowInvalidServerResponse() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        try await a.store.insert(host("nas"))
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()
        let stored = await transport.storedRecords

        let bogusPages = [
            ("records without advancing", RecordsPage(records: stored, nextSince: 0, hasMore: true)),
            ("records going backwards", RecordsPage(records: stored, nextSince: 0, hasMore: false)),
            ("hasMore without records", RecordsPage(records: [], nextSince: 0, hasMore: true)),
        ]
        for (name, page) in bogusPages {
            let scripted = ScriptedFetchTransport(inner: transport, page: page)
            let store = InMemoryStore(deviceID: "mac-b")
            let engine = SyncEngine(transport: scripted, store: store, deviceID: "mac-b", iterations: iterations)
            _ = try await engine.join(passphrase: passphrase, mode: .merge)
            do {
                _ = try await engine.sync()
                XCTFail("expected .invalidServerResponse: \(name)")
            } catch {
                XCTAssertEqual(error as? SyncError, .invalidServerResponse, name)
            }
        }
    }

    func testChangePassphraseWithStaleRewrapThrowsVaultChanged() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        _ = try await a.engine.createVault(passphrase: passphrase)
        let b = device("mac-b", transport)
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)

        let bEngine = b.engine
        let passphrase = passphrase
        await transport.onNextRewrap {
            try await bEngine.changePassphrase(old: passphrase, new: "b phrase")
        }
        do {
            try await a.engine.changePassphrase(old: passphrase, new: "a phrase")
            XCTFail("expected .vaultChanged")
        } catch {
            XCTAssertEqual(error as? SyncError, .vaultChanged)
        }

        _ = try await device("mac-c", transport).engine.join(passphrase: "b phrase", mode: .merge)
        do {
            _ = try await device("mac-d", transport).engine.join(passphrase: "a phrase", mode: .merge)
            XCTFail("expected .wrongPassphrase")
        } catch {
            XCTAssertEqual(error as? SyncError, .wrongPassphrase)
        }
    }

    func testPushFailureOnLaterBatchKeepsEarlierBatchesClean() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        for i in 0..<1_200 { try await a.store.insert(host("h\(i)")) }
        _ = try await a.engine.createVault(passphrase: passphrase)

        await transport.failUpsert(afterSuccessfulCalls: 1)
        do {
            _ = try await a.engine.sync()
            XCTFail("expected the injected failure")
        } catch {
            XCTAssertEqual(error as? InMemoryTransportError, .injectedFailure)
        }
        let stored = await transport.storedRecords
        XCTAssertEqual(stored.count, 500)
        for record in stored {
            let dirty = await a.store.isDirty(record.id)
            XCTAssertFalse(dirty)
        }
        let dirtyCount = await a.store.dirtyCount
        XCTAssertEqual(dirtyCount, 700)

        let report = try await a.engine.sync()
        XCTAssertEqual(report.pushed, 700)
        let remaining = await a.store.dirtyCount
        XCTAssertEqual(remaining, 0)
        let total = await transport.storedRecords.count
        XCTAssertEqual(total, 1_200)
    }

    func testPullAppliesServerRecordsWithoutPushingDirtyOnes() async throws {
        let transport = InMemoryTransport()
        let a = device("mac-a", transport)
        let nas = host("nas")
        try await a.store.insert(nas)
        _ = try await a.engine.createVault(passphrase: passphrase)
        _ = try await a.engine.sync()

        let b = device("mac-b", transport)
        let local = host("laptop")
        try await b.store.insert(local)
        _ = try await b.engine.join(passphrase: passphrase, mode: .merge)
        let report = try await b.engine.pull()

        XCTAssertEqual(report, SyncReport(pushed: 0, pulled: 1))
        let pulled = try await b.store.model(Host.self, id: nas.id)
        XCTAssertEqual(pulled?.label, "nas")
        let stored = await transport.storedRecords
        XCTAssertEqual(stored.map(\.id), [nas.id])
        let stillDirty = await b.store.isDirty(local.id)
        XCTAssertTrue(stillDirty)
        let state = await b.store.syncState
        XCTAssertEqual(state.lastSeq, 1)
    }

    func testPullWhileLockedThrows() async throws {
        let transport = InMemoryTransport()
        do {
            _ = try await device("mac-a", transport).engine.pull()
            XCTFail("expected .locked")
        } catch {
            XCTAssertEqual(error as? SyncError, .locked)
        }
    }
}

private actor SinceRecorder {
    private(set) var values: [Int64] = []
    func record(_ since: Int64) { values.append(since) }
}

/// Delegates to `inner` but answers every `fetch` with `page`; gives up after 10 fetches so a
/// looping engine fails the test instead of hanging it.
private final class ScriptedFetchTransport: SyncTransport {
    struct TooManyFetches: Error {}

    let inner: InMemoryTransport
    let page: RecordsPage
    private let fetches = SinceRecorder()

    init(inner: InMemoryTransport, page: RecordsPage) {
        self.inner = inner
        self.page = page
    }

    func getVault() async throws -> VaultMetadata? { try await inner.getVault() }
    func putVault(_ metadata: VaultMetadata) async throws { try await inner.putVault(metadata) }
    func rewrap(_ request: RewrapRequest) async throws -> VaultMetadata { try await inner.rewrap(request) }
    func upsert(_ records: [EncryptedRecord]) async throws -> [EncryptedRecord] { try await inner.upsert(records) }

    func fetch(since: Int64, limit: Int) async throws -> RecordsPage {
        await fetches.record(since)
        guard await fetches.values.count <= 10 else { throw TooManyFetches() }
        return page
    }
}
