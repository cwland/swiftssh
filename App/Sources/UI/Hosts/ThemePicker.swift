import SwiftUI
import AppCore

/// The Theme row of Host Details: a small swatch and the current choice ("Nord",
/// "Default (Dracula — from group)", "Unknown theme (<id>)"), with a chevron. Clicking it opens
/// `ThemeGalleryPopover`.
struct ThemeRowButton: View {
    let title: String
    /// What the host's tabs draw with now; nil = Automatic.
    let swatchTheme: TerminalTheme?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ThemeSwatch(theme: swatchTheme, size: CGSize(width: 33, height: 22))
                Text(title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose the terminal theme; click a theme to try it, Esc or click outside to close")
        .accessibilityLabel("Theme, \(title)")
    }
}

/// A popover holding a two-column `ThemeGallery`. Clicking a card calls `onSelect` (the caller
/// saves it at once) and the popover stays open so themes can be compared; Esc or a click
/// outside closes it.
struct ThemeGalleryPopover: View {
    let title: String
    /// nil = Default.
    let selectedThemeID: String?
    /// What Default resolves to; nil = Automatic.
    let inheritedTheme: TerminalTheme?
    /// The stored id when this build's catalog doesn't know it: no card is selected and a note
    /// says so. The id is kept until the user picks a theme.
    var unknownThemeID: String? = nil
    var catalog: TerminalThemeCatalog = .shared
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let unknownThemeID {
                    Text("Unknown theme (\(unknownThemeID)) \u{2014} saved by a newer version. Tabs use Default until you choose a theme.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                ThemeGallery(catalog: catalog, selectedThemeID: selectedThemeID, inheritedTheme: inheritedTheme,
                             showsDefault: true, columns: 2, onSelect: onSelect)
                    .padding(14)
            }
        }
        .frame(width: 480, height: 470)
    }
}
