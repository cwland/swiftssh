import Foundation

public enum MergeRule {
    /// Last-writer-wins per whole record: newer `updatedAt` wins; on an exact tie the
    /// larger `deviceID` string wins. An identical (updatedAt, deviceID) pair never wins,
    /// so re-sending the same record is idempotent.
    public static func incomingWins(
        _ incoming: (updatedAt: Date, deviceID: String),
        over existing: (updatedAt: Date, deviceID: String)
    ) -> Bool {
        if incoming.updatedAt != existing.updatedAt {
            return incoming.updatedAt > existing.updatedAt
        }
        return incoming.deviceID > existing.deviceID
    }
}
