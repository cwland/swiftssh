import Foundation
import Observation

/// Settings → Terminal, stored per Mac in UserDefaults (never synced).
@MainActor @Observable
public final class TerminalSettings {
    static let defaultThemeKey = "terminal.defaultThemeID"
    static let fontSizeKey = "terminal.fontSize"
    public static let fontSizeRange = 9...24
    public static let defaultFontSize = 13

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalog: TerminalThemeCatalog

    // Observed storage; the public properties below validate and persist.
    private var storedThemeID: String?
    private var storedFontSize: Int

    /// nil = Automatic. Setting nil removes the key; an id the catalog doesn't know is ignored
    /// (the value stays as it was).
    public var defaultThemeID: String? {
        get { storedThemeID }
        set {
            if let newValue, !catalog.contains(newValue) { return }
            storedThemeID = newValue
            if let newValue {
                defaults.set(newValue, forKey: Self.defaultThemeKey)
            } else {
                defaults.removeObject(forKey: Self.defaultThemeKey)
            }
        }
    }

    /// Text size in points. Clamped to `fontSizeRange` on set and on read.
    public var fontSize: Int {
        get { Self.clamped(storedFontSize) }
        set {
            let size = Self.clamped(newValue)
            storedFontSize = size
            defaults.set(size, forKey: Self.fontSizeKey)
        }
    }

    public var canIncreaseFontSize: Bool { fontSize < Self.fontSizeRange.upperBound }
    public var canDecreaseFontSize: Bool { fontSize > Self.fontSizeRange.lowerBound }

    /// One point bigger; does nothing at 24.
    public func increaseFontSize() {
        guard canIncreaseFontSize else { return }
        fontSize += 1
    }

    /// One point smaller; does nothing at 9.
    public func decreaseFontSize() {
        guard canDecreaseFontSize else { return }
        fontSize -= 1
    }

    /// Back to the default size (13 pt) — "Actual Size".
    public func resetFontSize() {
        fontSize = Self.defaultFontSize
    }

    /// A stored id the catalog doesn't know reads as nil (Automatic).
    public init(defaults: UserDefaults = .standard, catalog: TerminalThemeCatalog = .shared) {
        self.defaults = defaults
        self.catalog = catalog
        storedThemeID = defaults.string(forKey: Self.defaultThemeKey).flatMap { catalog.contains($0) ? $0 : nil }
        storedFontSize = Self.clamped(defaults.object(forKey: Self.fontSizeKey) as? Int ?? Self.defaultFontSize)
    }

    private static func clamped(_ size: Int) -> Int {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}
