import SwiftUI
import AppCore

/// The theme gallery used everywhere a theme is chosen: Settings → Terminal, the Host Details
/// popover, the group "Theme…" popover and the tab's Change Theme side panel.
///
/// A grid of `ThemeCard`s in `columns` columns: "Default" first when `showsDefault`, then every
/// catalog theme in catalog order. `selectedThemeID == nil` selects Default; an id the catalog
/// doesn't know selects no card. `onSelect(nil)` means Default. Clicking a card only calls
/// `onSelect`; the caller saves and decides whether to stay open.
///
/// The gallery does not scroll by itself (it sits inside the Settings pane's scroll view):
/// wrap it in a `ScrollView` in popovers and panels.
struct ThemeGallery: View {
    let catalog: TerminalThemeCatalog
    /// nil = Default.
    let selectedThemeID: String?
    /// What Default resolves to (drawn on the Default card and named in its subtitle);
    /// nil = Automatic (Reimagined Light/Dark following the appearance).
    let inheritedTheme: TerminalTheme?
    let showsDefault: Bool
    let columns: Int
    let onSelect: (String?) -> Void

    init(catalog: TerminalThemeCatalog = .shared, selectedThemeID: String?, inheritedTheme: TerminalTheme?,
         showsDefault: Bool = true, columns: Int = 2, onSelect: @escaping (String?) -> Void) {
        self.catalog = catalog
        self.selectedThemeID = selectedThemeID
        self.inheritedTheme = inheritedTheme
        self.showsDefault = showsDefault
        self.columns = columns
        self.onSelect = onSelect
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading),
                                 count: max(1, columns)),
                  alignment: .leading, spacing: 10) {
            if showsDefault {
                ThemeCard(defaultShowing: inheritedTheme, isSelected: selectedThemeID == nil) {
                    onSelect(nil)
                }
            }
            ForEach(catalog.themes) { theme in
                ThemeCard(theme: theme, isSelected: selectedThemeID == theme.id) {
                    onSelect(theme.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Themes")
    }
}

/// One gallery card: the swatch tile, then the name with "Dark"/"Light" (or "Default · <name>")
/// under it. The selected card has an accent ring around its tile.
struct ThemeCard: View {
    /// Drawn in the tile; nil = Automatic (light and dark split on the diagonal).
    let swatchTheme: TerminalTheme?
    let title: String
    let subtitle: String
    let helpText: String
    let isSelected: Bool
    let select: () -> Void

    /// A catalog theme.
    init(theme: TerminalTheme, isSelected: Bool, select: @escaping () -> Void) {
        swatchTheme = theme
        title = theme.name
        subtitle = theme.appearance == .light ? "Light" : "Dark"
        if let credit = theme.credit {
            helpText = "\(theme.name) \u{2014} by \(credit.author), \(credit.license)"
        } else {
            helpText = theme.name
        }
        self.isSelected = isSelected
        self.select = select
    }

    /// The Default card, showing what Default resolves to (`nil` = Automatic).
    init(defaultShowing inherited: TerminalTheme?, isSelected: Bool, select: @escaping () -> Void) {
        swatchTheme = inherited
        title = "Default"
        let name = inherited?.name ?? "Automatic"
        subtitle = "Default \u{00B7} \(name)"
        helpText = inherited == nil
            ? "Default \u{2014} Automatic: Reimagined Light or Reimagined Dark, following the appearance"
            : "Default \u{2014} uses \(name)"
        self.isSelected = isSelected
        self.select = select
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                ThemeSwatch(theme: swatchTheme)
                    .padding(3)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: ThemeSwatch.cornerRadius + 3, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 2)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: Theme.cardSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// A miniature terminal tile in the theme's own colors, drawn with shapes (no images, so nothing
/// to cache): background with a thin muted border; row 1 a long foreground bar; row 2 a selection
/// band holding two foreground bars; row 3 a short ANSI-green bar, two short foreground bars and a
/// cursor block. Everything scales with `size` (designed at 72 × 48). `theme == nil` is Automatic:
/// Reimagined Light and Reimagined Dark split on the diagonal.
struct ThemeSwatch: View {
    static let defaultSize = CGSize(width: 72, height: 48)
    static let cornerRadius: CGFloat = 7

    let theme: TerminalTheme?
    var size: CGSize = ThemeSwatch.defaultSize

    var body: some View {
        let radius = Self.cornerRadius * size.height / Self.defaultSize.height
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let theme {
                ThemeSwatchContent(theme: theme)
            } else {
                let catalog = TerminalThemeCatalog.shared
                ZStack {
                    ThemeSwatchContent(theme: catalog.automatic(prefersDark: false))
                    ThemeSwatchContent(theme: catalog.automatic(prefersDark: true))
                        .clipShape(SwatchLowerRightTriangle())
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(borderColor, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    /// The theme's foreground, faded: visible on its own background, quiet next to the bars.
    private var borderColor: Color {
        guard let theme else { return Color.primary.opacity(0.2) }
        return theme.foreground.swiftUIColor.opacity(0.28)
    }
}

/// The bars of one swatch, laid out in units of 1/48 of the tile's height.
private struct ThemeSwatchContent: View {
    let theme: TerminalTheme

    var body: some View {
        GeometryReader { proxy in
            let unit = proxy.size.height / ThemeSwatch.defaultSize.height
            let barHeight = 4 * unit
            let foreground = theme.foreground.swiftUIColor
            ZStack(alignment: .topLeading) {
                theme.background.swiftUIColor
                VStack(alignment: .leading, spacing: 5 * unit) {
                    bar(foreground, width: 42 * unit, height: barHeight)

                    HStack(spacing: 4 * unit) {
                        bar(foreground, width: 14 * unit, height: barHeight)
                        bar(foreground, width: 20 * unit, height: barHeight)
                    }
                    .padding(.horizontal, 3 * unit)
                    .frame(height: 10 * unit)
                    .background {
                        RoundedRectangle(cornerRadius: 2 * unit, style: .continuous)
                            .fill(theme.selection.swiftUIColor)
                    }
                    .padding(.horizontal, -3 * unit)

                    HStack(spacing: 3 * unit) {
                        bar(theme.ansi[2].swiftUIColor, width: 9 * unit, height: barHeight)
                        bar(foreground, width: 7 * unit, height: barHeight)
                        bar(foreground, width: 11 * unit, height: barHeight)
                        RoundedRectangle(cornerRadius: 1 * unit, style: .continuous)
                            .fill(theme.cursor.swiftUIColor)
                            .frame(width: 5 * unit, height: 9 * unit)
                    }
                    .frame(height: 9 * unit)
                }
                .padding(.leading, 9 * unit)
                .padding(.top, 7 * unit)
            }
        }
    }

    private func bar(_ color: Color, width: CGFloat, height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
    }
}

/// The bottom-right half of a rectangle, cut along the diagonal.
private struct SwatchLowerRightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
