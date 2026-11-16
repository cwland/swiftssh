import Foundation
import SSHCore

/// Why a sign-in with 1Password's SSH agent was refused, worked out from what the agent offers right
/// after the failure. Never involves a secret: only public keys and their names.
public enum AgentAuthFailure: Equatable, Sendable {
    /// The agent lists no keys (e.g. the keys are in a vault agent.toml doesn't name).
    case offersNoKeys
    /// The host is pinned to a key the agent doesn't list; its name (comment) or type.
    case pinnedKeyNotOffered(name: String)
    /// macOS refused access to the agent's socket ("Data shared by 1Password" is off).
    case blocked
    /// The agent didn't answer: 1Password is locked, quitting, or not running.
    case notAnswering
    /// The agent offers the key; the server turned it down (authorized_keys).
    case serverRejected

    /// Decides from the agent's answer: an error is `.blocked` (permission) or `.notAnswering`; no keys
    /// is `.offersNoKeys`; a pinned key that isn't listed is `.pinnedKeyNotOffered`; else the server.
    public static func diagnose(pinnedPublicKey: String?, listing: Result<[AgentKey], any Error>) -> AgentAuthFailure {
        switch listing {
        case .failure(let error):
            if let agentError = error as? SSHAgentError, agentError == .permissionDenied { return .blocked }
            return .notAnswering
        case .success(let keys):
            if keys.isEmpty { return .offersNoKeys }
            if let pinned = pinnedPublicKey, !AgentKeyMatch.offers(keys, pinned) {
                return .pinnedKeyNotOffered(name: AgentKeyMatch.displayName(pinned))
            }
            return .serverRejected
        }
    }

    /// The tab's message; `who` is "user@host".
    public func message(who: String) -> String {
        switch self {
        case .offersNoKeys:
            "1Password\u{2019}s SSH agent offers no keys, so it had none to try for \(who). If your keys are in a vault other than Private, choose the vaults the agent uses."
        case .pinnedKeyNotOffered(let name):
            "1Password\u{2019}s SSH agent doesn\u{2019}t offer the key this host uses (\(name)), so it couldn\u{2019}t sign in to \(who). Its vault may not be one the agent uses: choose the vaults, or pick another key in Host Details."
        case .blocked:
            "macOS is blocking SwiftSSH from 1Password\u{2019}s SSH agent. In System Settings \u{2192} Privacy & Security \u{2192} Files & Folders, turn on \u{201C}Data shared by 1Password\u{201D} for SwiftSSH, then quit and reopen SwiftSSH."
        case .notAnswering:
            "1Password is locked or not running, so its SSH agent couldn\u{2019}t sign in to \(who). Open 1Password, unlock it, and try again."
        case .serverRejected:
            "The server didn\u{2019}t accept the key from 1Password\u{2019}s SSH agent for \(who). Add the key\u{2019}s public half to ~/.ssh/authorized_keys on the server (Host Details \u{2192} \u{201C}Copy key-install command\u{201D})."
        }
    }

    public var suggestedAction: SuggestedAction {
        switch self {
        case .offersNoKeys, .pinnedKeyNotOffered: .chooseOnePasswordVaults
        case .blocked, .notAnswering, .serverRejected: .openOnePasswordSetup
        }
    }
}
