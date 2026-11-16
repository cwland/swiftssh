import Foundation

/// iPhone/iPad terminal themes: a short built-in list, picked once in Settings and used for every
/// session. Host and group themes set on the Mac are not used on iOS.
public enum CompanionThemes {
    /// The ids offered in Settings, in display order.
    static let ids = ["reimagined-dark", "reimagined-light", "dracula", "nord",
                      "solarized-dark", "solarized-light", "everforest-dark", "hacker-green"]

    /// The themes offered in Settings (besides Automatic).
    public static func choices(catalog: TerminalThemeCatalog = .shared) -> [TerminalTheme] {
        ids.compactMap { catalog.theme(id: $0) }
    }

    public static var choices: [TerminalTheme] { choices() }

    /// The chosen theme; Automatic (by the colour scheme) when nothing or a theme outside the list
    /// is chosen.
    public static func theme(selectedID: String?, prefersDark: Bool,
                             catalog: TerminalThemeCatalog = .shared) -> TerminalTheme {
        if let selectedID, ids.contains(selectedID), let theme = catalog.theme(id: selectedID) {
            return theme
        }
        return catalog.automatic(prefersDark: prefersDark)
    }
}
