import XCTest
import CoreModels
import SyncCore
@testable import AppCore

@MainActor
final class LogsViewModelTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func makeVault() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testRowsNewestFirst() async throws {
        let vault = try await makeVault()
        let old = try await vault.save(ConnectionLog(hostLabel: "old", username: "u", deviceName: "Mac",
                                                      startedAt: date(2026, 6, 1, 8, 0), endedAt: date(2026, 6, 1, 9, 0)))
        let new = try await vault.save(ConnectionLog(hostLabel: "new", username: "u", deviceName: "Mac",
                                                      startedAt: date(2026, 6, 26, 8, 0), endedAt: date(2026, 6, 26, 9, 0)))
        _ = try await vault.save(ConnectionLog(hostLabel: "gone", username: "u", deviceName: "Mac",
                                                startedAt: date(2026, 7, 1, 8, 0), deleted: true))
        let vm = LogsViewModel(vault: vault, timeZone: utc)
        XCTAssertEqual(vm.rows.map(\.id), [new.id, old.id])
        XCTAssertEqual(vm.rows.first?.dateText, "Jun 26, 2026")
        XCTAssertEqual(vm.rows.first?.hostLabel, "new")
        XCTAssertEqual(vm.rows.first?.timeRangeText, "08:00 - 09:00")
    }

    func testTimeRangeAcrossMidnightShowsPlusDays() async throws {
        let vault = try await makeVault()
        _ = try await vault.save(ConnectionLog(hostLabel: "h", username: "u", deviceName: "Mac",
                                                startedAt: date(2026, 6, 26, 23, 45), endedAt: date(2026, 6, 27, 23, 15)))
        _ = try await vault.save(ConnectionLog(hostLabel: "h2", username: "u", deviceName: "Mac",
                                                startedAt: date(2026, 6, 20, 23, 45), endedAt: date(2026, 6, 23, 0, 5)))
        let vm = LogsViewModel(vault: vault, timeZone: utc)
        XCTAssertEqual(vm.rows.map(\.timeRangeText), ["23:45 - 23:15 (+1d)", "23:45 - 00:05 (+3d)"])
    }

    func testOpenSessionShowsEllipsis() async throws {
        let vault = try await makeVault()
        _ = try await vault.save(ConnectionLog(hostLabel: "h", username: "u", deviceName: "Mac",
                                                startedAt: date(2026, 6, 26, 7, 5)))
        let vm = LogsViewModel(vault: vault, timeZone: utc)
        XCTAssertEqual(vm.rows.first?.timeRangeText, "07:05 - \u{2026}")
    }

    func testToggleSavedPersists() async throws {
        let vault = try await makeVault()
        let log = try await vault.save(ConnectionLog(hostLabel: "h", username: "u", deviceName: "Mac",
                                                      startedAt: date(2026, 6, 26, 7, 5)))
        let vm = LogsViewModel(vault: vault, timeZone: utc)
        XCTAssertEqual(vm.rows.first?.saved, false)
        vm.toggleSaved(id: log.id)
        XCTAssertEqual(vm.rows.first?.saved, true)
        XCTAssertEqual(vault.get(ConnectionLog.self, id: log.id)?.saved, true)
        vm.toggleSaved(id: log.id)
        XCTAssertEqual(vm.rows.first?.saved, false)
        vm.toggleSaved(id: UUID()) // unknown id is a no-op
    }

    func testBadgeComesFromHostIfStillPresent() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "srv", address: "a", osBadge: .linux))
        let when = date(2026, 6, 26, 7, 5)
        _ = try await vault.save(ConnectionLog(hostID: host.id, hostLabel: "srv", username: "u", deviceName: "Mac",
                                                startedAt: when))
        _ = try await vault.save(ConnectionLog(hostID: UUID(), hostLabel: "missing", username: "u", deviceName: "Mac",
                                                startedAt: when.addingTimeInterval(-60)))
        let vm = LogsViewModel(vault: vault, timeZone: utc)
        XCTAssertEqual(vm.rows.map(\.badge), [.linux, nil])
        try await vault.delete(SavedHost.self, id: host.id)
        XCTAssertEqual(vm.rows.map(\.badge), [nil, nil])
    }
}
