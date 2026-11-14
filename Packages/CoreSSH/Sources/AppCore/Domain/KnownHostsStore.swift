import Foundation
import CoreModels
import SSHCore

/// Trust decisions over the vault's `KnownHost` records (OpenSSH semantics: a host may have
/// one trusted key per key type).
@MainActor
public final class KnownHostsStore {
    private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    /// `known` when a live record has the same host, key type and fingerprint. A different
    /// fingerprint for the same key type is `changed`. A host with live records only for other key
    /// types is `newKeyType`; `unknown` means the host has no live records.
    public func check(_ candidate: HostKeyCandidate) -> HostKeyCheck {
        let hostRecords = records(for: candidate.hostPort)
        if hostRecords.isEmpty { return .unknown }
        let sameType = hostRecords.filter { $0.keyType == candidate.keyType }
        if sameType.contains(where: { $0.fingerprintSHA256 == candidate.fingerprint }) { return .known }
        // Most recent by `updatedAt`; ties go to the later-inserted record.
        guard let latest = sameType.reduce(nil as KnownHost?, { best, r in
            guard let best else { return r }
            return r.updatedAt >= best.updatedAt ? r : best
        }) else {
            var types: [String] = []
            for r in hostRecords where !types.contains(r.keyType) { types.append(r.keyType) }
            return .newKeyType(knownKeyTypes: types)
        }
        return .changed(previousFingerprint: latest.fingerprintSHA256)
    }

    /// Records the key as trusted and returns true. Returns false and changes nothing when a live
    /// record of the same key type with a different fingerprint exists for the host: only `replace`
    /// may supersede a key. Applied synchronously, persisted in the background.
    @discardableResult
    public func trust(_ candidate: HostKeyCandidate) -> Bool {
        let base64 = candidate.publicKeyBlob.base64EncodedString()
        let sameType = records(for: candidate.hostPort).filter { $0.keyType == candidate.keyType }
        if var existing = sameType.first(where: { $0.fingerprintSHA256 == candidate.fingerprint }) {
            if existing.publicKeyBase64 != base64 {
                existing.publicKeyBase64 = base64
                vault.saveNow(existing)
            }
            return true
        }
        guard sameType.isEmpty else { return false }
        vault.saveNow(KnownHost(hostPort: candidate.hostPort, keyType: candidate.keyType,
                                fingerprintSHA256: candidate.fingerprint, publicKeyBase64: base64))
        return true
    }

    /// Tombstones every record for the candidate's host (all key types), then trusts the candidate.
    public func replace(_ candidate: HostKeyCandidate) {
        for var record in records(for: candidate.hostPort) {
            record.deleted = true
            vault.saveNow(record)
        }
        let trusted = trust(candidate)
        assert(trusted, "replace tombstoned every record for the host")
    }

    /// One `known_hosts` line per live record that has a stored key. Records whose fields could
    /// alter the file's structure (whitespace, newlines, wildcards, markers) are skipped, so a
    /// malicious synced record cannot inject extra lines or match other hosts.
    public func knownHostsFileLines() -> [String] {
        vault.all(KnownHost.self).compactMap { record in
            guard let base64 = record.publicKeyBase64,
                  Self.isSafeHostPort(record.hostPort),
                  Self.isSafeKeyType(record.keyType),
                  Self.isSafeBase64(base64),
                  Self.blobMatches(record, base64: base64) else { return nil }
            return "\(record.hostPort) \(record.keyType) \(base64)"
        }
    }

    private func records(for hostPort: String) -> [KnownHost] {
        vault.all(KnownHost.self).filter { $0.hostPort == hostPort }
    }

    private static func isSafeHostPort(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !"@#|!".unicodeScalars.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value > 0x20 && scalar.value < 0x7F && !"*?,".unicodeScalars.contains(scalar)
        }
    }

    private static let keyTypeChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-@._")
    private static let base64Chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")

    private static func isSafeKeyType(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { keyTypeChars.contains($0) }
    }

    /// The blob must decode, hash to the record's fingerprint and start with the record's key type.
    private static func blobMatches(_ record: KnownHost, base64: String) -> Bool {
        guard let blob = Data(base64Encoded: base64),
              HostKeyFormat.fingerprintSHA256(publicKeyBlob: blob) == record.fingerprintSHA256,
              blob.count >= 4 else { return false }
        let bytes = [UInt8](blob)
        let length = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
        guard length <= bytes.count - 4 else { return false }
        return Data(bytes[4..<(4 + length)]) == Data(record.keyType.utf8)
    }

    private static func isSafeBase64(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { base64Chars.contains($0) }
    }
}

/// Asks the user (through `ask`) only for unknown or changed keys and records accepted ones.
public struct PromptingHostKeyEvaluator: HostKeyEvaluator {
    private let store: KnownHostsStore
    private let ask: @Sendable @MainActor (HostKeyCandidate, HostKeyCheck) async -> HostKeyDecision

    public init(store: KnownHostsStore,
                ask: @escaping @Sendable @MainActor (HostKeyCandidate, HostKeyCheck) async -> HostKeyDecision) {
        self.store = store
        self.ask = ask
    }

    public func evaluate(_ candidate: HostKeyCandidate) async -> HostKeyDecision {
        await evaluateOnMain(candidate)
    }

    @MainActor
    private func evaluateOnMain(_ candidate: HostKeyCandidate) async -> HostKeyDecision {
        // The store can change while the user is deciding (e.g. a concurrent connection to the same
        // host), so re-check after every answer and ask again when the situation is no longer the one
        // the user was shown.
        while true {
            let check = store.check(candidate)
            if check == .known { return .trusted }
            guard await ask(candidate, check) == .trusted else { return .rejected }
            let current = store.check(candidate)
            if current == .known { return .trusted }
            guard current == check else { continue }
            switch check {
            case .unknown, .newKeyType:
                if store.trust(candidate) { return .trusted }
            case .changed:
                store.replace(candidate)
                return .trusted
            case .known:
                break // unreachable: handled above, kept for exhaustiveness
            }
        }
    }
}
