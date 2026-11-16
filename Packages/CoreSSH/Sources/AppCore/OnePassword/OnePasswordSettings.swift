import Foundation
import Observation

/// Settings → 1Password → Advanced: where to find the agent socket and `op` when they aren't in the
/// usual places. Stored per Mac in UserDefaults (never synced). A blank value is stored as nothing.
@MainActor @Observable
public final class OnePasswordSettings {
    static let agentSocketOverrideKey = "onepassword.agentSocketOverride"
    static let cliPathOverrideKey = "onepassword.cliPathOverride"
    static let bringsPromptForwardKey = "onepassword.bringsPromptForward"

    @ObservationIgnored private let defaults: UserDefaults
    private var storedAgentSocketOverride: String?
    private var storedCLIPathOverride: String?

    /// nil = look in `OnePasswordPaths.agentSocketCandidates`. May start with "~/".
    public var agentSocketOverride: String? {
        get { storedAgentSocketOverride }
        set {
            storedAgentSocketOverride = OnePasswordPaths.nonBlank(newValue)
            store(storedAgentSocketOverride, Self.agentSocketOverrideKey)
        }
    }

    /// nil = look in `OnePasswordPaths.cliCandidates`.
    public var cliPathOverride: String? {
        get { storedCLIPathOverride }
        set {
            storedCLIPathOverride = OnePasswordPaths.nonBlank(newValue)
            store(storedCLIPathOverride, Self.cliPathOverrideKey)
        }
    }

    /// Hands the keyboard focus to 1Password while its Touch ID / approval prompt is showing
    /// (`OnePasswordPromptFocus`). On by default.
    public var bringsPromptForward: Bool {
        didSet { defaults.set(bringsPromptForward, forKey: Self.bringsPromptForwardKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedAgentSocketOverride = OnePasswordPaths.nonBlank(defaults.string(forKey: Self.agentSocketOverrideKey))
        storedCLIPathOverride = OnePasswordPaths.nonBlank(defaults.string(forKey: Self.cliPathOverrideKey))
        bringsPromptForward = defaults.object(forKey: Self.bringsPromptForwardKey) as? Bool ?? true
    }

    private func store(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
