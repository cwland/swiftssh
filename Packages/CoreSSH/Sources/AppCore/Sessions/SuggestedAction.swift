/// A next step the UI can offer next to a connection error.
public enum SuggestedAction: Equatable, Sendable {
    case openOnePasswordSetup
    /// 1Password's SSH agent doesn't offer the key: choose the vaults it offers keys from (agent.toml).
    case chooseOnePasswordVaults
    /// iPhone/iPad: no imported key signs in to this host; import one (the Keys screen).
    case importKey
}
