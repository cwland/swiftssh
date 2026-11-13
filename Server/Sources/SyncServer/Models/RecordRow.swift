import CoreModels
import Fluent
import Foundation
import SyncCore
import Vapor

extension UpsertRequest: @retroactive Content {}
extension UpsertResponse: @retroactive Content {}
extension RecordsPage: @retroactive Content {}

/// One encrypted record. `updated_at` is integer milliseconds since 1970 (the wire precision),
/// so merge comparisons on the server are exact rather than floating-point.
final class RecordRow: Model, @unchecked Sendable {
    static let schema = "records"

    @ID(key: .id) var id: UUID?
    @Field(key: "type") var type: SyncRecordType
    @Field(key: "updated_at") var updatedAtMillis: Int64
    @Field(key: "deleted") var deleted: Bool
    @Field(key: "device_id") var deviceID: String
    @Field(key: "seq") var seq: Int64
    @Field(key: "ciphertext") var ciphertext: Data

    init() {}

    init(_ record: EncryptedRecord, seq: Int64) {
        self.id = record.id
        apply(record, seq: seq)
    }

    func apply(_ record: EncryptedRecord, seq: Int64) {
        type = record.type
        updatedAtMillis = Self.millis(record.updatedAt)
        deleted = record.deleted
        deviceID = record.deviceID
        self.seq = seq
        ciphertext = record.ciphertext
    }

    /// The stored version's merge key, as `MergeRule` compares it.
    var mergeKey: (updatedAt: Date, deviceID: String) {
        (Self.date(updatedAtMillis), deviceID)
    }

    var record: EncryptedRecord {
        EncryptedRecord(
            id: id!, type: type, updatedAt: Self.date(updatedAtMillis), deleted: deleted,
            deviceID: deviceID, seq: seq, ciphertext: ciphertext)
    }

    /// Whole milliseconds, rounded down like `Timestamps` and the client's record AAD.
    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// Same conversion `JSONDecoder` uses for `.millisecondsSince1970`, so values round-trip exactly.
    static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }
}
