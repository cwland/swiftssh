import Foundation
import Observation

/// The app window's appearance (Settings sidebar, bottom).
public enum AppAppearance: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// App appearance, stored per Mac in UserDefaults (`app.appearance`, never synced). The app
/// applies it to `NSApp.appearance` through `onChange`, so it takes effect live.
@MainActor @Observable
public final class AppAppearanceSetting {
    static let key = "app.appearance"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public var onChange: (@MainActor (AppAppearance) -> Void)?

    public var appearance: AppAppearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Self.key)
            onChange?(appearance)
        }
    }

    /// A missing or unknown stored value is `.system`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Self.key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}
