import Foundation
import Observation

/// What the device said when the iPhone/iPad app asked to unlock.
public enum AppLockAuthentication: Equatable, Sendable {
    case success
    /// Face ID / Touch ID / the passcode was refused or cancelled; the message says what to do.
    case failed(String)
    /// The device can't authenticate at all (no passcode set): the app can't stay locked.
    case unavailable(String)
}

/// The iPhone/iPad app's optional lock (Settings → Face ID app lock). When it is on, the app is
/// locked at launch and when it comes back after more than `gracePeriod` in the background; while
/// locked, and whenever the app isn't active (the app switcher snapshot), a cover hides its content.
///
/// The setting lives in `UserDefaults` under `enabledKey`. Turning it off unlocks at once; turning it
/// on doesn't lock until the next launch or a return after the grace period.
@MainActor @Observable
public final class AppLock {
    public static let enabledKey = "appLockEnabled"
    /// Background time allowed before the app locks again.
    public static let gracePeriod: TimeInterval = 30

    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                isLocked = false
                message = nil
            }
        }
    }
    public private(set) var isLocked: Bool
    public private(set) var isAuthenticating = false
    /// Why the last unlock didn't work (or why the lock gave way); nil after a success.
    public private(set) var message: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticate: @MainActor () async -> AppLockAuthentication
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var backgroundedAt: Date?

    /// Reads the setting; the app starts locked when it is on.
    public init(defaults: UserDefaults = .standard,
                authenticate: @escaping @MainActor () async -> AppLockAuthentication,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.authenticate = authenticate
        self.now = now
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.isLocked = enabled
    }

    /// Whether the cover hides the app: while locked, and while the app isn't active when the lock is on.
    public func showsCover(isActive: Bool) -> Bool {
        isLocked || (isEnabled && !isActive)
    }

    /// The app went to the background.
    public func didEnterBackground() {
        backgroundedAt = now()
    }

    /// The app is active again: locks when it was in the background longer than `gracePeriod`.
    public func didBecomeActive() {
        defer { backgroundedAt = nil }
        guard isEnabled, let backgroundedAt else { return }
        if now().timeIntervalSince(backgroundedAt) > Self.gracePeriod {
            isLocked = true
        }
    }

    /// Asks for Face ID / Touch ID / the passcode. One request at a time.
    public func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        switch await authenticate() {
        case .success:
            isLocked = false
            message = nil
        case .failed(let reason):
            message = reason
        case .unavailable(let reason):
            // Nothing could ever unlock it: let the user in, and say why.
            isLocked = false
            message = reason
        }
    }
}
