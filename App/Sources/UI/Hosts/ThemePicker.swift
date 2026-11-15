import SwiftUI
import AppKit
import AppCore

/// Menu picker: "Default (<inherited name>)", a divider, then every catalog theme with a dot in its
/// background color. nil = Default (inherit).
struct ThemePicker: View {
    @Binding var themeID: String?
    /// Name shown in "Default (…)": e.g. "Nord — from group", or "Automatic" / the app default's name.
    let defaultLabel: String
    /// The stored id when this build's catalog doesn't know it; shown as "Unknown theme (<id>)".
    var unknownThemeID: String? = nil
    var catalog: TerminalThemeCatalog = .shared

    var body: some View {
        Picker("Theme", selection: $themeID) {
            Text("Default (\(defaultLabel))").tag(String?.none)
            Divider()
            if let unknownThemeID {
                Text("Unknown theme (\(unknownThemeID))").tag(String?.some(unknownThemeID))
                Divider()
            }
            ForEach(catalog.themes) { theme in
                ThemeMenuLabel(theme: theme).tag(String?.some(theme.id))
            }
        }
        .labelsHidden()
    }
}

/// The "Theme" submenu for a group card's context menu. "Default" first; a checkmark marks the
/// current choice.
struct GroupThemeMenu: View {
    let currentThemeID: String?
    let select: (String?) -> Void
    var catalog: TerminalThemeCatalog = .shared

    var body: some View {
        Toggle("Default", isOn: binding(for: nil))
        Divider()
        ForEach(catalog.themes) { theme in
            Toggle(isOn: binding(for: theme.id)) {
                ThemeMenuLabel(theme: theme)
            }
        }
    }

    /// A checkmark when `id` is the current choice; turning it on selects it.
    private func binding(for id: String?) -> Binding<Bool> {
        Binding(get: { currentThemeID == id }, set: { isOn in
            if isOn { select(id) }
        })
    }
}

/// A theme's name with a dot in its background color (a non-template image, so menus keep the color).
private struct ThemeMenuLabel: View {
    let theme: TerminalTheme

    var body: some View {
        Label {
            Text(theme.name)
        } icon: {
            Image(nsImage: Self.dot(fill: theme.background, border: theme.foreground))
        }
    }

    private static func dot(fill: AppCore.RGBColor, border: AppCore.RGBColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            fill.nsColor.setFill()
            path.fill()
            border.nsColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
