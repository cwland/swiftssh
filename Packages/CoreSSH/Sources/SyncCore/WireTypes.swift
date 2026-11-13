import Foundation
import CoreModels

public struct EncryptedRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var type: SyncRecordType
    public var updatedAt: Date
    public var deleted: Bool
    public var deviceID: String
    public var seq: Int64?
    public var ciphertext: Data

    public init(id: UUID, type: SyncRecordType, updatedAt: Date, deleted: Bool,
                deviceID: String, seq: Int64? = nil, ciphertext: Data) {
        self.id = id
        self.type = type
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.deviceID = deviceID
        self.seq = seq
        self.ciphertext = ciphertext
    }
}

public struct VaultMetadata: Codable, Equatable, Sendable {
    public var vaultID: UUID
    public var salt: Data
    public var iterations: Int
    public var wrappedKey: Data
    public var version: Int

    public init(vaultID: UUID, salt: Data, iterations: Int, wrappedKey: Data, version: Int = 1) {
        self.vaultID = vaultID
        self.salt = salt
        self.iterations = iterations
        self.wrappedKey = wrappedKey
        self.version = version
    }
}

public struct RecordsPage: Codable, Equatable, Sendable {
    public var records: [EncryptedRecord]
    public var nextSince: Int64
    public var hasMore: Bool

    public init(records: [EncryptedRecord], nextSince: Int64, hasMore: Bool) {
        self.records = records
        self.nextSince = nextSince
        self.hasMore = hasMore
    }
}

public struct UpsertRequest: Codable, Equatable, Sendable {
    public var records: [EncryptedRecord]

    public init(records: [EncryptedRecord]) {
        self.records = records
    }
}

/// The server's resulting copy of each submitted record, with `seq` assigned.
public struct UpsertResponse: Codable, Equatable, Sendable {
    public var records: [EncryptedRecord]

    public init(records: [EncryptedRecord]) {
        self.records = records
    }
}

public struct RewrapRequest: Codable, Equatable, Sendable {
    public var oldWrappedKey: Data
    public var salt: Data
    public var iterations: Int
    public var wrappedKey: Data

    public init(oldWrappedKey: Data, salt: Data, iterations: Int, wrappedKey: Data) {
        self.oldWrappedKey = oldWrappedKey
        self.salt = salt
        self.iterations = iterations
        self.wrappedKey = wrappedKey
    }
}
