import Foundation
import CoreModels
import SyncCore

/// Matches a joining Mac's local records against the vault's (spec §7, "Joining an existing
/// vault", Merge), so merging doesn't double up items:
///
/// - a host matches on lowercased, trimmed address + port (nil = 22) + username (nil = "");
/// - an identity matches on label + username;
/// - an SSH key matches on its public key's type and base64 blob (the comment is ignored).
///
/// Only non-deleted records match, and never a local record with the vault record's own id.
/// The first vault record wins when several are equal. Each matched local record is dropped
/// (removed locally, no tombstone) and every reference to it from the remaining local records
/// (host identity/key, identity key, group default identity, log and shell-history host) is
/// re-pointed to the vault's id.
public enum JoinDeduplicator {
    public struct Plan: Equatable, Sendable {
        /// Local duplicates to remove without uploading a tombstone.
        public var removedIDs: Set<UUID>
        /// Local duplicate id → the matching vault record's id.
        public var idMap: [UUID: UUID]
        /// Remaining local records whose references changed, re-encoded; `updatedAt` and
        /// `deviceID` are still the old ones (the vault stamps them as local edits).
        public var updated: [PlainRecord]

        public init(removedIDs: Set<UUID> = [], idMap: [UUID: UUID] = [:], updated: [PlainRecord] = []) {
            self.removedIDs = removedIDs
            self.idMap = idMap
            self.updated = updated
        }
    }

    public static func plan(local: [PlainRecord], vault: [PlainRecord]) -> Plan {
        let vaultIDs = Set(vault.map(\.id))
        let candidates = local.filter { !$0.deleted && !vaultIDs.contains($0.id) }

        var idMap: [UUID: UUID] = [:]
        match(SSHKey.self, local: candidates, vault: vault, key: keyMatchKey, into: &idMap)
        match(Identity.self, local: candidates, vault: vault, key: identityMatchKey, into: &idMap)
        match(CoreModels.Host.self, local: candidates, vault: vault, key: hostMatchKey, into: &idMap)

        let removed = Set(idMap.keys)
        var updated: [PlainRecord] = []
        if !idMap.isEmpty {
            for record in local where !removed.contains(record.id) && !vaultIDs.contains(record.id) {
                if let changed = try? repoint(record, idMap) { updated.append(changed) }
            }
        }
        return Plan(removedIDs: removed, idMap: idMap, updated: updated)
    }

    /// `payload` (the JSON of a model of `type`) with its top-level `updatedAt` set to
    /// `updatedAt`, encoded as the models encode dates. Works for any payload, whichever model
    /// wrote it (the highlight rules share `.aiSettings` with `AISettings`); every other field,
    /// known or not, is kept. Throws when `payload` isn't a JSON object. `type` is not needed and
    /// kept for callers.
    public static func restamp(_ payload: Data, type _: SyncRecordType, updatedAt: Date) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw RestampError.notAnObject
        }
        let stamp = try CoreJSON.encoder.encode(["updatedAt": updatedAt])
        guard let encoded = try JSONSerialization.jsonObject(with: stamp) as? [String: Any],
              let value = encoded["updatedAt"] else { throw RestampError.notAnObject }
        json["updatedAt"] = value
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    public enum RestampError: Error, Equatable, Sendable {
        /// The record's payload isn't a JSON object.
        case notAnObject
    }

    // MARK: Matching keys

    static func hostMatchKey(_ host: CoreModels.Host) -> String {
        let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(address)\u{0}\(host.port ?? 22)\u{0}\(host.username ?? "")"
    }

    static func identityMatchKey(_ identity: Identity) -> String {
        "\(identity.label)\u{0}\(identity.username)"
    }

    /// "<type> <base64>" of an OpenSSH public key line, without the comment.
    static func keyMatchKey(_ key: SSHKey) -> String {
        key.publicKey.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
    }

    private static func match<M: SyncableModel>(_: M.Type, local: [PlainRecord], vault: [PlainRecord],
                                                key: (M) -> String, into idMap: inout [UUID: UUID]) {
        var vaultByKey: [String: UUID] = [:]
        for record in vault where record.type == M.recordType && !record.deleted {
            guard let model = try? record.decode(M.self) else { continue }
            let k = key(model)
            if !k.isEmpty, vaultByKey[k] == nil { vaultByKey[k] = record.id }
        }
        for record in local where record.type == M.recordType {
            guard let model = try? record.decode(M.self), let target = vaultByKey[key(model)] else { continue }
            idMap[record.id] = target
        }
    }

    // MARK: Re-pointing

    /// The record re-encoded with references in `idMap` replaced, or nil when nothing changed.
    private static func repoint(_ record: PlainRecord, _ idMap: [UUID: UUID]) throws -> PlainRecord? {
        func mapped(_ id: UUID?) -> UUID? { id.flatMap { idMap[$0] ?? $0 } }
        func rewrite<M: SyncableModel>(_: M.Type, _ change: (inout M) -> Void) throws -> PlainRecord? {
            let original = try record.decode(M.self)
            var model = original
            change(&model)
            guard model != original else { return nil }
            var result = record
            result.payload = try PlainRecord.encode(model, keepingUnknownFieldsOf: record.payload)
            return result
        }
        switch record.type {
        case .host:
            return try rewrite(CoreModels.Host.self) {
                $0.identityID = mapped($0.identityID)
                $0.sshKeyID = mapped($0.sshKeyID)
            }
        case .identity:
            return try rewrite(Identity.self) { $0.sshKeyID = mapped($0.sshKeyID) }
        case .hostGroup:
            return try rewrite(HostGroup.self) { $0.defaultIdentityID = mapped($0.defaultIdentityID) }
        case .connectionLog:
            return try rewrite(ConnectionLog.self) { $0.hostID = mapped($0.hostID) }
        case .shellHistory:
            return try rewrite(ShellHistoryEntry.self) { $0.hostID = mapped($0.hostID) }
        case .sshKey, .snippet, .knownHost, .aiSettings:
            return nil
        }
    }
}
