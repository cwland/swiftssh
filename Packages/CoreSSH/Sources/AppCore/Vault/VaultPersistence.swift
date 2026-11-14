import Foundation
import SyncCore

/// What is stored in the local vault file. `records` is in insertion order.
public struct VaultFileContents: Codable, Equatable, Sendable {
    public var version: Int
    public var deviceID: String
    public var syncState: SyncState
    public var records: [PlainRecord]
    public var dirty: Set<UUID>

    public init(version: Int = 1, deviceID: String, syncState: SyncState = SyncState(vaultID: nil, lastSeq: 0),
                records: [PlainRecord] = [], dirty: Set<UUID> = []) {
        self.version = version
        self.deviceID = deviceID
        self.syncState = syncState
        self.records = records
        self.dirty = dirty
    }
}

public protocol VaultPersistence: Sendable {
    func load() async throws -> VaultFileContents?
    func save(_ contents: VaultFileContents) async throws
}

public struct InMemoryPersistenceError: Error, Equatable, Sendable {
    public init() {}
}

/// A `VaultPersistence` that keeps the contents in memory; for tests and previews.
public actor InMemoryVaultPersistence: VaultPersistence {
    public private(set) var contents: VaultFileContents?
    public private(set) var saveCount = 0
    private var failing = false

    public init(contents: VaultFileContents? = nil) {
        self.contents = contents
    }

    /// While true, `save` throws `InMemoryPersistenceError` and stores nothing.
    public func setFailing(_ failing: Bool) {
        self.failing = failing
    }

    public func load() async throws -> VaultFileContents? {
        contents
    }

    public func save(_ contents: VaultFileContents) async throws {
        if failing { throw InMemoryPersistenceError() }
        self.contents = contents
        saveCount += 1
    }
}
