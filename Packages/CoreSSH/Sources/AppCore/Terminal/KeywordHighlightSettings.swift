import Foundation
import Observation

/// A group of words (or, for `.network`, addresses) that keyword highlighting colours alike.
/// Order = the order of the colour wells in Settings → Terminal → Keyword highlighting.
public enum KeywordCategory: String, CaseIterable, Sendable, Hashable, Identifiable {
    case error, warning, ok, info, debug, network

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .ok: "OK"
        case .info: "Info"
        case .debug: "Debug"
        case .network: "IP address & MAC"
        }
    }

    public var defaultColor: RGBColor {
        switch self {
        case .error: RGBColor(red: 0xE0, green: 0x66, blue: 0x66)
        case .warning: RGBColor(red: 0xF4, green: 0xC5, blue: 0x42)
        case .ok: RGBColor(red: 0x8C, green: 0xCB, blue: 0x5E)
        case .info: RGBColor(red: 0x4A, green: 0x90, blue: 0xE2)
        case .debug: RGBColor(red: 0x8B, green: 0x85, blue: 0xF0)
        case .network: RGBColor(red: 0xC8, green: 0x55, blue: 0x9E)
        }
    }

    /// Whole words matched case-insensitively. `.network` has none: it matches IPv4 (optional
    /// /prefix and :port left uncoloured), IPv6 and MAC addresses instead.
    public var keywords: [String] {
        switch self {
        case .error: ["error", "errors", "err", "fail", "failed", "failure", "fatal", "critical", "denied", "refused",
                      "exception", "panic"]
        case .warning: ["warn", "warning", "warnings", "deprecated", "caution"]
        case .ok: ["ok", "success", "successful", "succeeded", "done", "passed", "active", "running", "enabled", "up"]
        case .info: ["info", "notice", "note"]
        case .debug: ["debug", "trace", "verbose"]
        case .network: []
        }
    }
}

/// Settings → Terminal → Keyword highlighting, stored per Mac in UserDefaults (never synced):
/// `terminal.highlight.enabled` (Bool, default true) and `terminal.highlight.<category>` ("#RRGGBB";
/// absent = the category's default colour).
///
/// Main-actor bound (SwiftUI). Terminal code takes a `snapshot` (a Sendable value) and hands it to
/// `KeywordHighlighter(settings:)` / `update(settings:)`.
@MainActor @Observable
public final class KeywordHighlightSettings {
    public static let enabledKey = "terminal.highlight.enabled"

    public nonisolated static func colorKey(for category: KeywordCategory) -> String {
        "terminal.highlight.\(category.rawValue)"
    }

    /// Everything the highlighter needs, as a value.
    public struct Snapshot: Equatable, Sendable {
        public var isEnabled: Bool
        /// Missing entries mean the category's default colour.
        public var colors: [KeywordCategory: RGBColor]

        public init(isEnabled: Bool = true, colors: [KeywordCategory: RGBColor] = [:]) {
            self.isEnabled = isEnabled
            self.colors = colors
        }

        /// Enabled, default colours.
        public static let `default` = Snapshot()

        public func color(for category: KeywordCategory) -> RGBColor {
            colors[category] ?? category.defaultColor
        }

        public static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.isEnabled == rhs.isEnabled
                && KeywordCategory.allCases.allSatisfy { lhs.color(for: $0) == rhs.color(for: $0) }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private var storedEnabled: Bool
    private var storedColors: [KeywordCategory: RGBColor]

    public var isEnabled: Bool {
        get { storedEnabled }
        set {
            storedEnabled = newValue
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }

    public func color(for category: KeywordCategory) -> RGBColor {
        storedColors[category] ?? category.defaultColor
    }

    public func isDefaultColor(for category: KeywordCategory) -> Bool {
        storedColors[category] == nil
    }

    /// Setting a category's default colour removes its key.
    public func setColor(_ color: RGBColor, for category: KeywordCategory) {
        if color == category.defaultColor {
            resetColor(for: category)
            return
        }
        storedColors[category] = color
        defaults.set(color.hex, forKey: Self.colorKey(for: category))
    }

    public func resetColor(for category: KeywordCategory) {
        storedColors[category] = nil
        defaults.removeObject(forKey: Self.colorKey(for: category))
    }

    public func resetAllColors() {
        for category in KeywordCategory.allCases { resetColor(for: category) }
    }

    /// Observed: reading it in a view/observation scope tracks every setting.
    public var snapshot: Snapshot {
        Snapshot(isEnabled: storedEnabled, colors: storedColors)
    }

    /// An unparsable stored colour reads as the default.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        var colors: [KeywordCategory: RGBColor] = [:]
        for category in KeywordCategory.allCases {
            if let hex = defaults.string(forKey: Self.colorKey(for: category)), let color = RGBColor(hex: hex),
               color != category.defaultColor {
                colors[category] = color
            }
        }
        storedColors = colors
    }
}
