import XCTest
import CoreModels
@testable import SyncCore

/// A host as an app version from before the backup address (v1.1.0) decodes it: no `fallbackAddress`.
private struct HostBeforeBackupAddress: SyncableModel {
    static let recordType = SyncRecordType.host
    var id: UUID
    var label: String
    var address: String
    var updatedAt: Date
    var deleted: Bool
}

/// Older app versions keep a backup address they don't know about when they rewrite the host.
final class BackupAddressForwardCompatTests: XCTestCase {
    func testOlderVersionRewritingTheHostKeepsTheBackupAddress() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let host = CoreModels.Host(label: "NAS", address: "192.168.50.10", fallbackAddress: "100.64.0.10", updatedAt: date)
        let synced = try PlainRecord(host, deviceID: "mac-new")

        // The older app reads the record, renames the host and saves it.
        var old = try synced.decode(HostBeforeBackupAddress.self)
        old.label = "NAS 2"
        let rewritten = try PlainRecord(old, deviceID: "mac-old", keepingUnknownFieldsOf: synced)

        let back = try rewritten.decode(CoreModels.Host.self)
        XCTAssertEqual(back.label, "NAS 2")
        XCTAssertEqual(back.fallbackAddress, "100.64.0.10", "the older app kept the field it doesn't know")
    }
}
