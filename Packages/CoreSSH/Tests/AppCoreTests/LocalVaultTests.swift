import XCTest
import CoreModels
import SyncCore
@testable import AppCore

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

@MainActor
final class LocalVaultTests: XCTestCase {
    private func open(_ p: InMemoryVaultPersistence = InMemoryVaultPersistence()) async throws -> LocalVault {
        try await LocalVault.open(persistence: p, newDeviceID: { "dev-1" })
    }

    func testOpenWithNoFileStartsEmptyWithNewDeviceID() async throws {
        let vault = try await open()
        XCTAssertTrue(vault.all(Host.self).isEmpty)
        XCTAssertEqual(vault.deviceID, "dev-1")
    }

    func testSaveAssignsIncreasingUpdatedAtAndMarksDirty() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let host = Host(label: "a", address: "a.example")
        let first = try await vault.save(host)
        let second = try await vault.save(first)
        XCTAssertGreaterThan(second.updatedAt, first.updatedAt)
        let contents = await p.contents
        XCTAssertEqual(contents?.dirty, [host.id])
        XCTAssertEqual(vault.get(Host.self, id: host.id), second)
    }

    func testSavePersistsAndReopenRestores() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let b = try await vault.save(Host(label: "b", address: "b.example"))
        let a = try await vault.save(Host(label: "a", address: "a.example"))
        let reopened = try await LocalVault.open(persistence: p, newDeviceID: { "other" })
        XCTAssertEqual(reopened.deviceID, "dev-1")
        XCTAssertEqual(reopened.all(Host.self), [b, a])
    }

    func testDeleteIsTombstoneHiddenFromQueries() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let host = try await vault.save(Host(label: "a", address: "a.example"))
        try await vault.delete(Host.self, id: host.id)
        XCTAssertTrue(vault.all(Host.self).isEmpty)
        XCTAssertNil(vault.get(Host.self, id: host.id))
        let contents = await p.contents
        let record = try XCTUnwrap(contents?.records.first { $0.id == host.id })
        XCTAssertTrue(record.deleted)
        XCTAssertGreaterThan(record.updatedAt, host.updatedAt)
        XCTAssertTrue(contents?.dirty.contains(host.id) == true)
    }

    func testRevisionIncrementsOnEveryChange() async throws {
        let vault = try await open()
        let r0 = vault.revision
        let host = try await vault.save(Host(label: "a", address: "a.example"))
        let r1 = vault.revision
        try await vault.delete(Host.self, id: host.id)
        XCTAssertGreaterThan(r1, r0)
        XCTAssertGreaterThan(vault.revision, r1)
    }

    func testSaveFailureIsReportedAndInMemoryStateKept() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let first = try await vault.save(Host(label: "first", address: "f.example"))
        await p.setFailing(true)
        let host = Host(label: "a", address: "a.example")
        do {
            _ = try await vault.save(host)
            XCTFail("expected throw")
        } catch {}
        XCTAssertNotNil(vault.lastSaveError)
        let failed = try XCTUnwrap(vault.get(Host.self, id: host.id))
        await p.setFailing(false)
        let retried = try await vault.save(failed)
        XCTAssertNil(vault.lastSaveError)
        XCTAssertGreaterThan(retried.updatedAt, failed.updatedAt)
        let contents = await p.contents
        XCTAssertEqual(contents?.records.compactMap { try? $0.decode(Host.self) }, [first, retried])
        XCTAssertEqual(contents?.dirty, [first.id, host.id])
    }

    func testDeleteFailureKeepsTombstoneAndLaterWritePersistsIt() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let host = try await vault.save(Host(label: "a", address: "a.example"))
        await p.setFailing(true)
        do {
            try await vault.delete(Host.self, id: host.id)
            XCTFail("expected throw")
        } catch {}
        XCTAssertNil(vault.get(Host.self, id: host.id))
        XCTAssertNotNil(vault.lastSaveError)
        await p.setFailing(false)
        let other = try await vault.save(Host(label: "b", address: "b.example"))
        let contents = await p.contents
        let record = try XCTUnwrap(contents?.records.first { $0.id == host.id })
        XCTAssertTrue(record.deleted)
        XCTAssertEqual(contents?.dirty, [host.id, other.id])
    }

    func testUnsupportedVersionThrows() async throws {
        let p = InMemoryVaultPersistence(contents: VaultFileContents(version: 2, deviceID: "x"))
        do {
            _ = try await LocalVault.open(persistence: p)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? LocalVaultError, .unsupportedVersion(2))
        }
    }

    func testOverlappingSavesPersistLatestState() async throws {
        let p = GatedPersistence()
        let vault = try await LocalVault.open(persistence: p, newDeviceID: { "dev-1" })
        let a = Host(label: "a", address: "a.example")
        let b = Host(label: "b", address: "b.example")
        let taskA = Task { @MainActor in try await vault.save(a) }
        while await p.started < 1 { await Task.yield() }
        let taskB = Task { @MainActor in try await vault.save(b) }
        await p.release(2)
        await p.release(1)
        _ = try await taskA.value
        _ = try await taskB.value
        let contents = await p.contents
        XCTAssertEqual(Set(contents?.records.map(\.id) ?? []), [a.id, b.id])
        XCTAssertNil(vault.lastSaveError)
    }

    func testSaveNowAppliesImmediatelyAndPersistsAfterFlush() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let original = try await vault.save(Host(label: "a", address: "a.example"))
        let r0 = vault.revision
        var edited = original
        edited.label = "b"
        let stored = vault.saveNow(edited)
        XCTAssertEqual(vault.get(Host.self, id: original.id), stored)
        XCTAssertEqual(stored.label, "b")
        XCTAssertGreaterThan(stored.updatedAt, original.updatedAt)
        XCTAssertGreaterThan(vault.revision, r0)
        await vault.flush()
        let contents = await p.contents
        XCTAssertEqual(contents?.records.compactMap { try? $0.decode(Host.self) }, [stored])
        XCTAssertEqual(contents?.dirty, [original.id])
        XCTAssertNil(vault.lastSaveError)
    }

    func testRapidSaveNowCallsPersistTheLastState() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        var host = Host(label: "0", address: "a.example")
        for i in 1...20 {
            host.label = "\(i)"
            host = vault.saveNow(host)
        }
        await vault.flush()
        let contents = await p.contents
        XCTAssertEqual(contents?.records.compactMap { try? $0.decode(Host.self) }, [host])
    }

    func testSaveNowPersistFailureSetsLastSaveError() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        await p.setFailing(true)
        let host = vault.saveNow(Host(label: "a", address: "a.example"))
        await vault.flush()
        XCTAssertNotNil(vault.lastSaveError)
        XCTAssertEqual(vault.get(Host.self, id: host.id), host)
        await p.setFailing(false)
        vault.saveNow(host)
        await vault.flush()
        XCTAssertNil(vault.lastSaveError)
    }

    func testPersistNowThrowsOnFailureAndPersistsOnSuccess() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        let host = vault.saveNow(Host(label: "a", address: "a.example"))
        await p.setFailing(true)
        do {
            try await vault.persistNow()
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is InMemoryPersistenceError)
        }
        XCTAssertNotNil(vault.lastSaveError)
        await p.setFailing(false)
        try await vault.persistNow()
        XCTAssertNil(vault.lastSaveError)
        let contents = await p.contents
        XCTAssertEqual(contents?.records.compactMap { try? $0.decode(Host.self) }, [host])
    }

    func testFlushRetriesAfterAFailedWrite() async throws {
        let p = InMemoryVaultPersistence()
        let vault = try await open(p)
        await p.setFailing(true)
        let host = vault.saveNow(Host(label: "a", address: "a.example"))
        await vault.flush()
        XCTAssertNotNil(vault.lastSaveError)
        let failedContents = await p.contents
        XCTAssertNil(failedContents)
        await p.setFailing(false)
        await vault.flush()
        XCTAssertNil(vault.lastSaveError)
        let contents = await p.contents
        XCTAssertEqual(contents?.records.compactMap { try? $0.decode(Host.self) }, [host])
    }

    func testFlushWithNothingQueuedReturns() async throws {
        let vault = try await open()
        await vault.flush()
        XCTAssertNil(vault.lastSaveError)
    }
}

/// Test persistence whose n-th `save` call (1-based) blocks until `release(n)`.
private actor GatedPersistence: VaultPersistence {
    private(set) var contents: VaultFileContents?
    private(set) var started = 0
    private var released: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

    func release(_ n: Int) {
        released.insert(n)
        waiting.removeValue(forKey: n)?.resume()
    }

    func load() async throws -> VaultFileContents? { contents }

    func save(_ new: VaultFileContents) async throws {
        started += 1
        let n = started
        if !released.contains(n) {
            await withCheckedContinuation { waiting[n] = $0 }
        }
        contents = new
    }
}
