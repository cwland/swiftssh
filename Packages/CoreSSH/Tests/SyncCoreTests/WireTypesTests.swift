import XCTest
import CoreModels
@testable import SyncCore

final class WireTypesTests: XCTestCase {
    func testEncryptedRecordJSONRoundTrip() throws {
        let record = EncryptedRecord(
            id: UUID(),
            type: .host,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
            deleted: false,
            deviceID: "mac-a",
            seq: 42,
            ciphertext: Data([1, 2, 3, 4])
        )
        let data = try CoreJSON.encoder.encode(record)
        XCTAssertEqual(try CoreJSON.decoder.decode(EncryptedRecord.self, from: data), record)

        let noSeq = EncryptedRecord(id: UUID(), type: .host, updatedAt: record.updatedAt,
                                    deleted: true, deviceID: "b", seq: nil, ciphertext: Data())
        let d2 = try CoreJSON.encoder.encode(noSeq)
        XCTAssertEqual(try CoreJSON.decoder.decode(EncryptedRecord.self, from: d2), noSeq)
    }
}
