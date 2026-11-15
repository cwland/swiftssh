import Foundation
import Observation
import CoreModels

public enum KeyImportError: Error, Equatable, LocalizedError {
    case publicKeyMismatch

    public var errorDescription: String? {
        switch self {
        case .publicKeyMismatch:
            "The public key you entered doesn't match the private key."
        }
    }
}

@MainActor @Observable
public final class KeychainViewModel {
    public var searchText = ""

    @ObservationIgnored private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    private var needle: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var identities: [Identity] {
        _ = vault.revision
        let needle = self.needle
        return vault.all(Identity.self)
            .filter { needle.isEmpty || $0.label.lowercased().contains(needle) || $0.username.lowercased().contains(needle) }
            .sorted { Self.ordered($0.label, $0.id, $1.label, $1.id) }
    }

    public var keys: [SSHKey] {
        _ = vault.revision
        let needle = self.needle
        return vault.all(SSHKey.self)
            .filter { needle.isEmpty || $0.label.lowercased().contains(needle) }
            .sorted { Self.ordered($0.label, $0.id, $1.label, $1.id) }
    }

    private static func ordered(_ a: String, _ aID: UUID, _ b: String, _ bID: UUID) -> Bool {
        switch a.localizedCaseInsensitiveCompare(b) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: aID.uuidString < bID.uuidString
        }
    }

    // MARK: Usage

    public func usageSummary(identityID: UUID) -> String {
        Self.summary(count: usageCount(identityID: identityID))
    }

    public func usageSummary(sshKeyID: UUID) -> String {
        Self.summary(count: usageCount(sshKeyID: sshKeyID))
    }

    /// Hosts that would connect with this identity (explicitly linked, or inherited through a
    /// group default), as decided by `CredentialResolution`.
    public func usageCount(identityID: UUID) -> Int {
        resolutions().filter { $0.identity?.id == identityID }.count
    }

    /// Hosts that would connect with this key: the key of the identity in effect, or the host's
    /// own key when no identity applies.
    public func usageCount(sshKeyID: UUID) -> Int {
        resolutions().filter { $0.key?.id == sshKeyID }.count
    }

    private func resolutions() -> [CredentialResolution] {
        let hosts = vault.all(SavedHost.self)
        let directory = HostDirectory(hosts: hosts, groups: vault.all(HostGroup.self))
        return hosts.map { CredentialResolution.resolve(host: $0, directory: directory, vault: vault) }
    }

    private static func summary(count: Int) -> String {
        switch count {
        case 0: "Not used"
        case 1: "Used by 1 host"
        default: "Used by \(count) hosts"
        }
    }

    // MARK: Identities

    @discardableResult
    public func newIdentity() async throws -> Identity {
        try await vault.save(Identity(label: "New identity", username: ""))
    }

    public func update(_ identity: Identity) async throws {
        try await vault.save(identity)
    }

    /// Synchronous save for editors: applies `edited`'s label, username, password (empty = none),
    /// key (cleared if the key no longer exists) and 1Password agent key to the currently stored
    /// identity. A set agent key leaves the password and key stored (the agent takes precedence). Does
    /// nothing when the identity is missing or deleted, so a late edit never resurrects it.
    public func updateNow(_ edited: Identity) {
        guard var current = vault.get(Identity.self, id: edited.id) else { return }
        current.label = edited.label
        current.username = edited.username
        current.password = edited.password.flatMap { $0.isEmpty ? nil : $0 }
        if let keyID = edited.sshKeyID, vault.get(SSHKey.self, id: keyID) != nil {
            current.sshKeyID = keyID
        } else {
            current.sshKeyID = nil
        }
        current.agentKey = edited.agentKey
        vault.saveNow(current)
    }

    /// The saved secrets of the identity that `change` makes unnecessary; empty when it is missing or deleted.
    public func secretsReplaced(by change: CredentialChange, identityID: UUID) -> ReplacedSecrets {
        guard let identity = vault.get(Identity.self, id: identityID) else {
            return ReplacedSecrets(password: false, keyLink: false)
        }
        return Self.loginFields(of: identity).replaced(by: change)
    }

    /// Switches the identity's login to `change` and saves at once. With `removingReplaced`, the secrets
    /// `secretsReplaced(by:identityID:)` reports are removed too; otherwise they stay stored. The username
    /// and label are never touched, and a Keychain key item is never deleted. Does nothing when the
    /// identity is missing or deleted.
    public func apply(_ change: CredentialChange, identityID: UUID, removingReplaced: Bool) {
        guard var identity = vault.get(Identity.self, id: identityID) else { return }
        let before = identity
        var fields = Self.loginFields(of: identity)
        fields.apply(change, removingReplaced: removingReplaced)
        identity.password = fields.password
        identity.sshKeyID = fields.sshKeyID
        identity.agentKey = fields.agentKey
        if identity != before { vault.saveNow(identity) }
    }

    private static func loginFields(of identity: Identity) -> LoginFields {
        LoginFields(password: identity.password, sshKeyID: identity.sshKeyID, agentKey: identity.agentKey)
    }

    public func deleteIdentity(id: UUID) async throws {
        try await vault.deleteIdentity(id: id)
    }

    // MARK: Keys

    @discardableResult
    public func generateKey(label: String, type: KeyType) async throws -> SSHKey {
        let comment = Self.sanitizedComment(label)
        let generated: GeneratedKey
        switch type {
        case .ed25519:
            generated = SSHKeyGenerator.ed25519(comment: comment)
        case .rsa:
            generated = try await Task.detached(priority: .userInitiated) {
                try SSHKeyGenerator.rsa4096(comment: comment)
            }.value
        }
        return try await vault.save(SSHKey(label: label, keyType: generated.keyType,
                                           publicKey: generated.publicKey, privateKey: generated.privateKey))
    }

    @discardableResult
    public func importKey(label: String, privateKey: String, passphrase: String?, publicKey: String?) async throws -> SSHKey {
        let inspected = try SSHKeyImporter.inspect(privateKey: privateKey)
        var keyType = inspected.keyType
        var publicLine = inspected.publicKey ?? ""
        if let explicit = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            let (explicitType, explicitLine) = try SSHKeyImporter.parsePublicKey(explicit)
            if let derived = inspected.publicKey,
               explicitType != inspected.keyType || Self.keyBody(derived) != Self.keyBody(explicitLine) {
                throw KeyImportError.publicKeyMismatch
            }
            keyType = explicitType
            publicLine = explicitLine
        }
        let secret = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        return try await vault.save(SSHKey(label: label, keyType: keyType, publicKey: publicLine,
                                           privateKey: privateKey, passphrase: secret))
    }

    public func update(_ key: SSHKey) {
        vault.saveNow(key)
    }

    public func deleteKey(id: UUID) async throws {
        try await vault.deleteSSHKey(id: id)
    }

    public func publicKeyForCopy(sshKeyID: UUID) -> String? {
        _ = vault.revision
        guard let key = vault.get(SSHKey.self, id: sshKeyID), !key.publicKey.isEmpty else { return nil }
        return key.publicKey
    }

    // MARK: Helpers

    /// Newlines and control characters become spaces; the result is trimmed.
    private static func sanitizedComment(_ label: String) -> String {
        let mapped = String(String.UnicodeScalarView(label.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        return mapped.trimmingCharacters(in: .whitespaces)
    }

    /// `algorithm base64` without the comment.
    private static func keyBody(_ line: String) -> String {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(2).joined(separator: " ")
    }
}
