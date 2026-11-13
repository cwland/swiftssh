import Fluent
import Foundation
import SyncCore
import Vapor

extension VaultMetadata: @retroactive Content {}
extension RewrapRequest: @retroactive Content {}

/// The single vault's metadata. `slot` is always 1 and unique, so the database itself
/// guarantees at most one vault even under concurrent PUTs.
final class VaultRow: Model, @unchecked Sendable {
    static let schema = "vault"

    @ID(key: .id) var id: UUID?
    @Field(key: "slot") var slot: Int
    @Field(key: "salt") var salt: Data
    @Field(key: "iterations") var iterations: Int
    @Field(key: "wrapped_key") var wrappedKey: Data
    @Field(key: "version") var version: Int

    init() {}

    init(_ meta: VaultMetadata) {
        self.id = meta.vaultID
        self.slot = 1
        self.salt = meta.salt
        self.iterations = meta.iterations
        self.wrappedKey = meta.wrappedKey
        self.version = meta.version
    }

    var metadata: VaultMetadata {
        VaultMetadata(vaultID: id!, salt: salt, iterations: iterations, wrappedKey: wrappedKey, version: version)
    }
}
