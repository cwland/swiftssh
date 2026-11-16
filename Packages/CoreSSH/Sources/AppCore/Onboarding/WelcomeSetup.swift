import Foundation
import Observation
import CoreModels

/// The first-launch welcome sheet (Help → Set Up SwiftSSH… opens it any time): join the sync
/// server, set up 1Password, done.
///
/// It opens by itself at most once per launch, and only on a Mac that looks new: the vault has no
/// live records of any type (hosts, groups, identities, keys, snippets, known hosts, logs, history,
/// settings) and no sync server is saved. It stops opening by itself
/// once the user finishes it (Done) or ticks "Don't show again".
public enum WelcomeSetup {
    public enum Step: Int, CaseIterable, Sendable {
        case sync, onePassword, done

        public var title: String {
            switch self {
            case .sync: "Join your sync server"
            case .onePassword: "Set up 1Password"
            case .done: "You\u{2019}re set"
            }
        }

        /// "Step 1 of 3".
        public var progress: String { "Step \(rawValue + 1) of \(Self.allCases.count)" }

        public var next: Step? { Step(rawValue: rawValue + 1) }
        public var previous: Step? { Step(rawValue: rawValue - 1) }
    }

    /// Whether the vault holds nothing: no live record of any type (`LocalVault.liveCounts()`).
    public static func vaultIsEmpty(_ liveCounts: [SyncRecordType: Int]) -> Bool {
        liveCounts.values.allSatisfy { $0 == 0 }
    }

    /// Whether to open the welcome sheet at launch: a new-looking Mac (empty vault, no sync server)
    /// where the user hasn't finished or turned off the welcome.
    @MainActor
    public static func shouldShowAtLaunch(liveCounts: [SyncRecordType: Int], syncServerConfigured: Bool,
                                          settings: WelcomeSettings) -> Bool {
        !settings.dontShowAgain && vaultIsEmpty(liveCounts) && !syncServerConfigured
    }
}

/// The welcome sheet's per-Mac setting, in UserDefaults (never synced).
@MainActor @Observable
public final class WelcomeSettings {
    static let dontShowAgainKey = "welcome.dontShowAgain"

    @ObservationIgnored private let defaults: UserDefaults

    /// "Don't show again"; also set by Done. Help → Set Up SwiftSSH… opens it regardless.
    public var dontShowAgain: Bool {
        didSet { defaults.set(dontShowAgain, forKey: Self.dontShowAgainKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dontShowAgain = defaults.bool(forKey: Self.dontShowAgainKey)
    }
}
