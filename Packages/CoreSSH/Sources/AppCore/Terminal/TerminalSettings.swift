import Foundation
import Observation
import SSHCore

/// Settings → Terminal, stored per Mac in UserDefaults (never synced): theme, text size, font, the
/// behaviour toggles and the terminal type.
@MainActor @Observable
public final class TerminalSettings {
    static let defaultThemeKey = "terminal.defaultThemeID"
    static let fontSizeKey = "terminal.fontSize"
    static let fontNameKey = "terminal.fontName"
    static let openLinksKey = "terminal.openLinksWithCommandClick"
    static let selectToCopyKey = "terminal.selectToCopyRightClickToPaste"
    static let bellSoundKey = "terminal.bellSound"
    static let optionAsMetaDefaultsKey = "terminal.optionAsMetaKey"
    static let boldBrightKey = "terminal.boldUsesBrightColors"
    static let terminalTypeKey = "terminal.terminalType"
    public static let fontSizeRange = 9...24
    public static let defaultFontSize = 13

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalog: TerminalThemeCatalog

    // Observed storage; the public properties below validate and persist.
    private var storedThemeID: String?
    private var storedFontSize: Int
    private var storedFontName: String?

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

    /// The terminal font's family name; nil = SF Mono (the system monospaced font). Setting "" is
    /// the same as nil. A font that is no longer installed is drawn in SF Mono, but the choice is
    /// kept in case it comes back.
    public var fontName: String? {
        get { storedFontName }
        set {
            let name = newValue.flatMap { $0.isEmpty ? nil : $0 }
            storedFontName = name
            if let name {
                defaults.set(name, forKey: Self.fontNameKey)
            } else {
                defaults.removeObject(forKey: Self.fontNameKey)
            }
        }
    }

    /// ⌘-click opens http, https and mailto links (`TerminalLinkFilter`). Default on.
    public var opensLinksWithCommandClick: Bool {
        didSet { defaults.set(opensLinksWithCommandClick, forKey: Self.openLinksKey) }
    }

    /// Selecting text copies it; a right-click pastes. Default off.
    public var selectToCopyRightClickToPaste: Bool {
        didSet { defaults.set(selectToCopyRightClickToPaste, forKey: Self.selectToCopyKey) }
    }

    /// The bell (BEL) plays the system alert sound. Default off: the bell is silent.
    public var bellSound: Bool {
        didSet { defaults.set(bellSound, forKey: Self.bellSoundKey) }
    }

    /// Option sends Meta (ESC + key) instead of typing the layout's Option character. Default on.
    public var optionAsMetaKey: Bool {
        didSet { defaults.set(optionAsMetaKey, forKey: Self.optionAsMetaDefaultsKey) }
    }

    /// Bold text in ANSI colours 0–7 is drawn in the bright variants (8–15). Default off.
    public var boldUsesBrightColors: Bool {
        didSet { defaults.set(boldUsesBrightColors, forKey: Self.boldBrightKey) }
    }

    /// `TERM` for new connections (open tabs keep theirs until they reconnect). An unknown stored
    /// value reads as xterm-256color.
    public var terminalType: TerminalType {
        didSet { defaults.set(terminalType.rawValue, forKey: Self.terminalTypeKey) }
    }

    /// The behaviour toggles as one value, for the terminal view.
    public var behaviour: TerminalBehaviour {
        TerminalBehaviour(opensLinks: opensLinksWithCommandClick,
                          selectToCopyRightClickToPaste: selectToCopyRightClickToPaste,
                          bellSound: bellSound, optionAsMetaKey: optionAsMetaKey,
                          boldUsesBrightColors: boldUsesBrightColors)
    }

    /// What a tab draws with: `theme` plus this Mac's text size, font and behaviour. Reading it in
    /// a view's body makes the view follow every one of these settings.
    public func appearance(theme: TerminalTheme) -> TerminalAppearance {
        TerminalAppearance(theme: theme, fontSize: fontSize, fontName: fontName, behaviour: behaviour)
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
        storedFontName = defaults.string(forKey: Self.fontNameKey).flatMap { $0.isEmpty ? nil : $0 }
        let base = TerminalBehaviour()
        opensLinksWithCommandClick = defaults.object(forKey: Self.openLinksKey) as? Bool ?? base.opensLinks
        selectToCopyRightClickToPaste = defaults.object(forKey: Self.selectToCopyKey) as? Bool
            ?? base.selectToCopyRightClickToPaste
        bellSound = defaults.object(forKey: Self.bellSoundKey) as? Bool ?? base.bellSound
        optionAsMetaKey = defaults.object(forKey: Self.optionAsMetaDefaultsKey) as? Bool ?? base.optionAsMetaKey
        boldUsesBrightColors = defaults.object(forKey: Self.boldBrightKey) as? Bool ?? base.boldUsesBrightColors
        terminalType = defaults.string(forKey: Self.terminalTypeKey).flatMap(TerminalType.init(rawValue:)) ?? .default
    }

    private static func clamped(_ size: Int) -> Int {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}

/// Settings → Terminal → Behaviour, as one value. The defaults are the settings' defaults.
public struct TerminalBehaviour: Equatable, Sendable {
    public var opensLinks: Bool
    public var selectToCopyRightClickToPaste: Bool
    public var bellSound: Bool
    public var optionAsMetaKey: Bool
    public var boldUsesBrightColors: Bool

    public init(opensLinks: Bool = true, selectToCopyRightClickToPaste: Bool = false, bellSound: Bool = false,
                optionAsMetaKey: Bool = true, boldUsesBrightColors: Bool = false) {
        self.opensLinks = opensLinks
        self.selectToCopyRightClickToPaste = selectToCopyRightClickToPaste
        self.bellSound = bellSound
        self.optionAsMetaKey = optionAsMetaKey
        self.boldUsesBrightColors = boldUsesBrightColors
    }
}

/// The font picker's rules (the installed font list itself comes from AppKit).
public enum TerminalFontChoice {
    /// One face of a font family, as AppKit lists it (`availableMembers(ofFontFamily:)`).
    public struct Member: Equatable, Sendable {
        /// PostScript name.
        public var name: String
        /// AppKit weight, 0–15 (5 = regular).
        public var weight: Int
        public var isBold: Bool
        public var isItalic: Bool

        public init(name: String, weight: Int, isBold: Bool, isItalic: Bool) {
            self.name = name
            self.weight = weight
            self.isBold = isBold
            self.isItalic = isItalic
        }
    }

    /// The face to draw a family with: upright and not bold, nearest to regular weight (5; a tie
    /// goes to the lighter one); failing that, the upright face nearest to regular; failing that,
    /// the first face. nil only for an empty list.
    public static func preferredMember(_ members: [Member]) -> String? {
        func nearest(_ candidates: [Member]) -> Member? {
            candidates.enumerated().min { a, b in
                let da = abs(a.element.weight - 5), db = abs(b.element.weight - 5)
                if da != db { return da < db }
                if a.element.weight != b.element.weight { return a.element.weight < b.element.weight }
                return a.offset < b.offset
            }?.element
        }
        let upright = members.filter { !$0.isItalic }
        return (nearest(upright.filter { !$0.isBold }) ?? nearest(upright) ?? members.first)?.name
    }

    /// The picker's rows after "SF Mono": fixed-pitch families sorted by name (case-insensitive),
    /// without duplicates, empty names, hidden system families (leading ".") or SF Mono itself.
    public static func pickerFamilies(fixedPitch families: [String]) -> [String] {
        var seen = Set<String>()
        return families
            .filter { !$0.isEmpty && !$0.hasPrefix(".") && $0 != "SF Mono" && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
