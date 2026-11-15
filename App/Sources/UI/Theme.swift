import SwiftUI
import AppKit
import AppCore

/// Visual Reference tokens. The top bar stays navy in both appearances; content and sidebar
/// follow the system appearance.
enum Theme {
    // Top bar
    static let topBarBackground = Color(hex: "#23263A")
    /// The selected tab.
    static let tabBackground = Color(hex: "#41455E")
    /// Every other tab: its own box, so you can see where one tab ends and the next begins.
    static let tabInactiveBackground = Color(hex: "#2D3046")
    static let topBarForeground = Color.white
    static let topBarHeight: CGFloat = 52
    static let tabCornerRadius: CGFloat = 10
    static let tabFontSize: CGFloat = 15
    /// Leading space kept clear for the window's traffic-light buttons.
    static let trafficLightInset: CGFloat = 78

    // Sidebar
    static let sidebarWidth: CGFloat = 220
    static let sidebarBackground = Color.dynamic(light: "#F6F7F9", dark: .controlBackground)
    static let sidebarSelection = Color.dynamic(light: "#E6E8EC", dark: .quaternaryLabel)
    static let sidebarRowCornerRadius: CGFloat = 10
    static let sidebarFontSize: CGFloat = 17

    // Content
    static let contentBackground = Color.dynamic(light: "#EEF0F2", dark: .windowBackground)
    static let searchFieldBackground = Color.dynamic(light: "#E4E7EB", dark: .quaternaryLabel)
    static let accent = Color(hex: "#3B82F6")
    /// Where a dragged tab or host lands on a terminal (the half that becomes the new pane).
    static let dropHighlight = Color(hex: "#22C55E")
    /// Cards stand apart from the content area: white on the light grey background, one step
    /// lighter than the background in Dark Aqua.
    static let cardBackground = Color.dynamic(light: "#FFFFFF", dark: .raisedSurface)
    static let cardCornerRadius: CGFloat = 12
    static let cardHeight: CGFloat = 60
    static let cardPadding: CGFloat = 12
    static let cardBadgeSize: CGFloat = 40
    static let cardBadgeCornerRadius: CGFloat = 9
    static let cardTitleFontSize: CGFloat = 15
    static let cardSubtitleFontSize: CGFloat = 12
    /// Host, group and keychain grids: as many columns of at least this width as fit (N → 3 → 2 → 1).
    static let cardMinimumWidth: CGFloat = 240
    static let cardSpacing: CGFloat = 16
    static let badgeSize: CGFloat = 60
    static let badgeCornerRadius: CGFloat = 12
    static let detailsPanelWidth: CGFloat = 380

    // Banners
    static let warningBackground = Color.orange.opacity(0.15)
    static let warningForeground = Color.orange
}

extension Color {
    /// A color from "#RRGGBB" (the leading "#" is optional). Malformed input gives gray.
    init(hex: String) {
        let rgb = Color.rgbComponents(hex: hex)
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// System colors used for Dark Aqua. (An enum rather than `NSColor` values so the dynamic
    /// provider closure captures only `Sendable` data.)
    enum DarkSystemColor: Sendable {
        case windowBackground, controlBackground, quaternaryLabel
        /// A light translucent layer: one step lighter than whatever dark background it sits on.
        case raisedSurface

        var nsColor: NSColor {
            switch self {
            case .windowBackground: NSColor.windowBackgroundColor
            case .controlBackground: NSColor.controlBackgroundColor
            case .quaternaryLabel: NSColor.quaternaryLabelColor
            case .raisedSurface: NSColor(white: 1, alpha: 0.08)
            }
        }
    }

    /// `light` (a "#RRGGBB" string) in Aqua; the system color `dark` in Dark Aqua.
    static func dynamic(light: String, dark: DarkSystemColor) -> Color {
        let rgb = rgbComponents(hex: light)
        let red = rgb.red
        let green = rgb.green
        let blue = rgb.blue
        let nsColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return dark.nsColor
            }
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        return Color(nsColor: nsColor)
    }

    /// "#RRGGBB" of this color in sRGB, nil if it can't be converted (e.g. a pattern color).
    var sRGBHex: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return BadgeColor.hex(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                              blue: Double(srgb.blueComponent))
    }

    static func rgbComponents(hex: String) -> (red: Double, green: Double, blue: Double) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            return (0.5, 0.5, 0.5)
        }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}

extension Theme {
    /// The adaptive card grid used by Hosts, groups and Keychain.
    static var cardGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: cardSpacing)]
    }
}

/// Termius-style card: a badge, then a single-line title (15 pt) and subtitle (12 pt).
struct CardRow<Badge: View>: View {
    let title: String
    let subtitle: String
    var isSelected = false
    /// When set, a pencil button at the right edge (while hovered or selected) opens the editor.
    var onEdit: (() -> Void)? = nil
    @ViewBuilder let badge: () -> Badge

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.cardPadding) {
            badge()
                .frame(width: Theme.cardBadgeSize, height: Theme.cardBadgeSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.cardTitleFontSize))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if let onEdit {
                CardEditButton(action: onEdit)
                    .opacity(isHovering || isSelected ? 1 : 0)
                    .allowsHitTesting(isHovering || isSelected)
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

/// The card's pencil: a rounded grey square (as in Termius) that opens the card's editor.
struct CardEditButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.16 : 0.09))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Edit")
        .accessibilityLabel("Edit")
    }
}

/// A rounded-square symbol badge for cards that have no OS badge (groups, identities, keys).
struct SymbolBadge: View {
    let symbol: String
    let background: Color
    var foreground: Color = .white

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.cardBadgeCornerRadius, style: .continuous)
            .fill(background)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: Theme.cardBadgeSize * 0.42, weight: .medium))
                    .foregroundStyle(foreground)
            }
    }
}
