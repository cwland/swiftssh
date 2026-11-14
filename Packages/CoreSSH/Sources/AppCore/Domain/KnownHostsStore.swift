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
    /// fingerprint for the same key type is `changed`. A host with records only for other key
    /// types is `unknown` for this one.
    public func check(_ candidate: HostKeyCandidate) -> HostKeyCheck {
        let sameType = records(for: candidate.hostPort).filter { $0.keyType == candidate.keyType }
        if sameType.contains(where: { $0.fingerprintSHA256 == candidate.fingerprint }) { return .known }
        // Most recent by `updatedAt`; ties go to the later-inserted record.
        guard let latest = sameType.reduce(nil as KnownHost?, { best, r in
            guard let best else { return r }
            return r.updatedAt >= best.updatedAt ? r : best
        }) else { return .unknown }
        return .changed(previousFingerprint: latest.fingerprintSHA256)
    }

    /// Records the key as trusted. The change is applied synchronously and persisted in the background.
    public func trust(_ candidate: HostKeyCandidate) {
        let base64 = candidate.publicKeyBlob.base64EncodedString()
        if var existing = records(for: candidate.hostPort).first(where: {
            $0.keyType == candidate.keyType && $0.fingerprintSHA256 == candidate.fingerprint
        }) {
            if existing.publicKeyBase64 != base64 {
                existing.publicKeyBase64 = base64
                vault.saveNow(existing)
            }
            return
        }
        vault.saveNow(KnownHost(hostPort: candidate.hostPort, keyType: candidate.keyType,
                                fingerprintSHA256: candidate.fingerprint, publicKeyBase64: base64))
    }

    /// Tombstones every record for the candidate's host (all key types), then trusts the candidate.
    public func replace(_ candidate: HostKeyCandidate) {
        for var record in records(for: candidate.hostPort) {
            record.deleted = true
            vault.saveNow(record)
        }
        trust(candidate)
    }

    /// One `known_hosts` line per live record that has a stored key. Records whose fields could
    /// alter the file's structure (whitespace, newlines, wildcards, markers) are skipped, so a
    /// malicious synced record cannot inject extra lines or match other hosts.
    public func knownHostsFileLines() -> [String] {
        vault.all(KnownHost.self).compactMap { record in
            guard let base64 = record.publicKeyBase64,
                  Self.isSafeHostPort(record.hostPort),
                  Self.isSafeKeyType(record.keyType),
                  Self.isSafeBase64(base64) else { return nil }
            return "\(record.hostPort) \(record.keyType) \(base64)"
        }
    }

    private func records(for hostPort: String) -> [KnownHost] {
        vault.all(KnownHost.self).filter { $0.hostPort == hostPort }
    }

    private static func isSafeHostPort(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !"@#|!".unicodeScalars.contains(first) else { return false }
        return !s.isEmpty && s.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value > 0x20 && scalar.value < 0x7F && !"*?,".unicodeScalars.contains(scalar)
        }
    }

    private static let keyTypeChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-@._")
    private static let base64Chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")

    private static func isSafeKeyType(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { keyTypeChars.contains($0) }
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
        let check = store.check(candidate)
        if check == .known { return .trusted }
        let decision = await ask(candidate, check)
        guard decision == .trusted else { return .rejected }
        switch check {
        case .known: break
        case .unknown: store.trust(candidate)
        case .changed: store.replace(candidate)
        }
        return .trusted
    }
}
