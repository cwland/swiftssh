import CoreModels
import Foundation

/// The single statement of which credentials a saved host uses. Both `ConnectionPlanner` and the
/// keychain usage counts go through it so they cannot drift.
///
/// Precedence: (a) the host's explicit `identityID`, if it resolves to a live identity, always
/// applies; (b) otherwise, if the host has any direct credential (username, non-empty password or
/// a live key), the host's own fields are used; (c) otherwise the group-inherited default identity
/// applies. A deleted or missing identity or key counts as absent.
///
/// Within the source that applies, a 1Password agent key (`agentKey`) wins over the key and password:
/// both are then nil. A host's own agent key counts as a direct credential.
struct CredentialResolution {
    /// The identity in effect, or nil when the host's own fields (or nothing) apply.
    var identity: Identity?
    var username: String?
    var password: String?
    var key: SSHKey?
    /// Non-nil = sign in with 1Password's SSH agent.
    var agentKey: AgentKeyChoice?

    @MainActor
    static func resolve(host: SavedHost, directory: HostDirectory, vault: LocalVault) -> CredentialResolution {
        func from(_ identity: Identity) -> CredentialResolution {
            CredentialResolution(identity: identity, username: nonEmpty(identity.username),
                                 password: nonEmpty(identity.password),
                                 key: identity.sshKeyID.flatMap { vault.get(SSHKey.self, id: $0) })
                .applyingAgentKey(identity.agentKey)
        }
        if let explicit = host.identityID.flatMap({ vault.get(Identity.self, id: $0) }) {
            return from(explicit)
        }
        let username = nonEmpty(host.username)
        let password = nonEmpty(host.password)
        let key = host.sshKeyID.flatMap { vault.get(SSHKey.self, id: $0) }
        if username != nil || password != nil || key != nil || host.agentKey != nil {
            return CredentialResolution(identity: nil, username: username, password: password, key: key)
                .applyingAgentKey(host.agentKey)
        }
        // Ignore the host's own (dead) link so the group default is reached.
        var inheriting = host
        inheriting.identityID = nil
        if let inherited = directory.effectiveIdentityID(for: inheriting).flatMap({ vault.get(Identity.self, id: $0) }) {
            return from(inherited)
        }
        return CredentialResolution(identity: nil, username: nil, password: nil, key: nil)
    }

    /// The agent key, when set, replaces the key and password.
    private func applyingAgentKey(_ agentKey: AgentKeyChoice?) -> CredentialResolution {
        guard let agentKey else { return self }
        return CredentialResolution(identity: identity, username: username, password: nil, key: nil, agentKey: agentKey)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
