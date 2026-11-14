import CoreModels
import Foundation

/// The single statement of which credentials a saved host uses. Both `ConnectionPlanner` and the
/// keychain usage counts go through it so they cannot drift.
///
/// Precedence: (a) the host's explicit `identityID`, if it resolves to a live identity, always
/// applies; (b) otherwise, if the host has any direct credential (username, non-empty password or
/// a live key), the host's own fields are used; (c) otherwise the group-inherited default identity
/// applies. A deleted or missing identity or key counts as absent.
struct CredentialResolution {
    /// The identity in effect, or nil when the host's own fields (or nothing) apply.
    var identity: Identity?
    var username: String?
    var password: String?
    var key: SSHKey?

    @MainActor
    static func resolve(host: SavedHost, directory: HostDirectory, vault: LocalVault) -> CredentialResolution {
        func from(_ identity: Identity) -> CredentialResolution {
            CredentialResolution(identity: identity, username: nonEmpty(identity.username),
                                 password: nonEmpty(identity.password),
                                 key: identity.sshKeyID.flatMap { vault.get(SSHKey.self, id: $0) })
        }
        if let explicit = host.identityID.flatMap({ vault.get(Identity.self, id: $0) }) {
            return from(explicit)
        }
        let username = nonEmpty(host.username)
        let password = nonEmpty(host.password)
        let key = host.sshKeyID.flatMap { vault.get(SSHKey.self, id: $0) }
        if username != nil || password != nil || key != nil {
            return CredentialResolution(identity: nil, username: username, password: password, key: key)
        }
        // Ignore the host's own (dead) link so the group default is reached.
        var inheriting = host
        inheriting.identityID = nil
        if let inherited = directory.effectiveIdentityID(for: inheriting).flatMap({ vault.get(Identity.self, id: $0) }) {
            return from(inherited)
        }
        return CredentialResolution(identity: nil, username: nil, password: nil, key: nil)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
