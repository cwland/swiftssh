import Foundation

/// Whether a theme is drawn on a light or a dark background.
public enum ThemeAppearance: String, Sendable, Hashable {
    case light, dark
}

/// Who made a bundled third-party theme, under which license, and where its colors came from.
public struct ThemeCredit: Hashable, Sendable {
    /// The key in the catalog's `credits` map, e.g. "dracula".
    public let key: String
    /// e.g. "Dracula".
    public let project: String
    public let author: String
    /// e.g. "MIT".
    public let license: String
    /// The copyright line of the upstream license file.
    public let copyright: String
    public let url: String
    /// Which upstream files the values were taken from.
    public let files: String

    public init(key: String, project: String, author: String, license: String, copyright: String,
                url: String, files: String) {
        self.key = key
        self.project = project
        self.author = author
        self.license = license
        self.copyright = copyright
        self.url = url
        self.files = files
    }
}

/// A terminal color theme from the bundled catalog (`TerminalThemeCatalog`).
public struct TerminalTheme: Identifiable, Hashable, Sendable {
    /// Stable slug, stored in synced records (`Host.themeID`, `HostGroup.defaultThemeID`): never renamed.
    public let id: String
    public let name: String
    public let appearance: ThemeAppearance
    public let background: RGBColor
    public let foreground: RGBColor
    public let cursor: RGBColor
    public let selection: RGBColor
    /// Exactly 16: normal 0–7 (black, red, green, yellow, blue, magenta, cyan, white), bright 8–15.
    public let ansi: [RGBColor]
    /// nil for the app's own themes.
    public let credit: ThemeCredit?

    /// `ansi` must hold exactly 16 colors (the catalog never builds a theme otherwise).
    public init(id: String, name: String, appearance: ThemeAppearance, background: RGBColor, foreground: RGBColor,
                cursor: RGBColor, selection: RGBColor, ansi: [RGBColor], credit: ThemeCredit?) {
        precondition(ansi.count == 16, "A terminal theme needs exactly 16 ANSI colors")
        self.id = id
        self.name = name
        self.appearance = appearance
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
        self.credit = credit
    }
}
