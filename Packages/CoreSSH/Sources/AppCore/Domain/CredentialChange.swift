import CoreModels
import Foundation

/// Switching a host's or identity's login to another method. Switching may make the saved secrets of the
/// old method unnecessary; `ReplacedSecrets` says which, so the app can offer to remove them.
public enum CredentialChange: Equatable, Sendable {
    /// Log in with the 1Password SSH agent.
    case agent(AgentKeyChoice)
    /// An op:// reference replaces the password.
    case passwordReference(String)
    /// A key from the app's Keychain.
    case key(UUID)
}

/// The saved secrets a `CredentialChange` makes unnecessary. A 1Password reference (op://…) is never a
/// secret here, and the username is never touched.
public struct ReplacedSecrets: Equatable, Sendable {
    /// A plain saved password would be removed.
    public var password: Bool
    /// The link to a Keychain key would be removed (the key item itself is kept).
    public var keyLink: Bool
    public var isEmpty: Bool { !password && !keyLink }

    public init(password: Bool, keyLink: Bool) {
        self.password = password
        self.keyLink = keyLink
    }
}

/// The rules, shared by hosts and identities, over the three login fields.
struct LoginFields: Equatable {
    var password: String?
    var sshKeyID: UUID?
    var agentKey: AgentKeyChoice?

    private var hasPlainPassword: Bool {
        guard let password, !password.isEmpty else { return false }
        return !SecretReference.isReference(password)
    }

    /// `.agent`: a plain password and the key link. `.passwordReference`: the key link only (the
    /// password is overwritten by the reference whatever the user chooses). `.key`: a plain password.
    func replaced(by change: CredentialChange) -> ReplacedSecrets {
        switch change {
        case .agent: ReplacedSecrets(password: hasPlainPassword, keyLink: sshKeyID != nil)
        case .passwordReference: ReplacedSecrets(password: false, keyLink: sshKeyID != nil)
        case .key: ReplacedSecrets(password: hasPlainPassword, keyLink: false)
        }
    }

    /// Applies `change`; with `removingReplaced`, also clears what `replaced(by:)` reports.
    mutating func apply(_ change: CredentialChange, removingReplaced: Bool) {
        let replaced = replaced(by: change)
        switch change {
        case .agent(let choice):
            agentKey = choice
        case .passwordReference(let reference):
            password = reference
            // The password is what logs in now; the agent would otherwise win over it.
            agentKey = nil
        case .key(let id):
            sshKeyID = id
            agentKey = nil
        }
        guard removingReplaced else { return }
        if replaced.password { password = nil }
        if replaced.keyLink { sshKeyID = nil }
    }
}
