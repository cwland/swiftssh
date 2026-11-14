import XCTest
import CoreModels
import SyncCore
@testable import AppCore

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
        await p.setFailing(true)
        let host = Host(label: "a", address: "a.example")
        do {
            _ = try await vault.save(host)
            XCTFail("expected throw")
        } catch {}
        XCTAssertNotNil(vault.lastSaveError)
        XCTAssertNotNil(vault.get(Host.self, id: host.id))
        await p.setFailing(false)
        _ = try await vault.save(host)
        XCTAssertNil(vault.lastSaveError)
    }
}
