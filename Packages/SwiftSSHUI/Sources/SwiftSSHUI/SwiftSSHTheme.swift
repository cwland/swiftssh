import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Visual Reference tokens, shared by the Mac and iPhone/iPad apps. The top bar stays navy in both
/// appearances; content and sidebar follow the system appearance. (The Mac app calls this `Theme`.)
public enum SwiftSSHTheme {
    // Top bar
    public static let topBarBackground = Color(hex: "#23263A")
    /// The selected tab.
    public static let tabBackground = Color(hex: "#41455E")
    /// Every other tab: its own box, so you can see where one tab ends and the next begins.
    public static let tabInactiveBackground = Color(hex: "#2D3046")
    public static let topBarForeground = Color.white
    public static let topBarHeight: CGFloat = 52
    public static let tabCornerRadius: CGFloat = 10
    public static let tabFontSize: CGFloat = 15
    /// Leading space kept clear for the Mac window's traffic-light buttons.
    public static let trafficLightInset: CGFloat = 78

    // Sidebar
    public static let sidebarWidth: CGFloat = 220
    public static let sidebarBackground = Color.dynamic(light: "#F6F7F9", dark: .controlBackground)
    public static let sidebarSelection = Color.dynamic(light: "#E6E8EC", dark: .quaternaryLabel)
    public static let sidebarRowCornerRadius: CGFloat = 10
    public static let sidebarFontSize: CGFloat = 17

    // Content
    public static let contentBackground = Color.dynamic(light: "#EEF0F2", dark: .windowBackground)
    public static let searchFieldBackground = Color.dynamic(light: "#E4E7EB", dark: .quaternaryLabel)
    public static let accent = Color(hex: "#3B82F6")
    /// Where a dragged tab or host lands on a terminal (the half that becomes the new pane).
    public static let dropHighlight = Color(hex: "#22C55E")
    /// Cards stand apart from the content area: white on the light grey background, one step
    /// lighter than the background in the dark appearance.
    public static let cardBackground = Color.dynamic(light: "#FFFFFF", dark: .raisedSurface)
    public static let cardCornerRadius: CGFloat = 12
    public static let cardHeight: CGFloat = 60
    public static let cardPadding: CGFloat = 12
    public static let cardBadgeSize: CGFloat = 40
    public static let cardBadgeCornerRadius: CGFloat = 9
    public static let cardTitleFontSize: CGFloat = 15
    public static let cardSubtitleFontSize: CGFloat = 12
    /// Host, group and keychain grids: as many columns of at least this width as fit (N → 3 → 2 → 1).
    public static let cardMinimumWidth: CGFloat = 240
    public static let cardSpacing: CGFloat = 16
    public static let badgeSize: CGFloat = 60
    public static let badgeCornerRadius: CGFloat = 12
    public static let detailsPanelWidth: CGFloat = 380

    // Banners
    public static let warningBackground = Color.orange.opacity(0.15)
    public static let warningForeground = Color.orange

    /// The adaptive card grid used by Hosts, groups and Keychain.
    public static var cardGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: cardSpacing)]
    }
}

extension Color {
    /// A color from "#RRGGBB" (the leading "#" is optional). Malformed input gives gray.
    public init(hex: String) {
        let rgb = Color.rgbComponents(hex: hex)
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// System colors used for the dark appearance. (An enum rather than platform color values so
    /// the dynamic provider closure captures only `Sendable` data.)
    public enum DarkSystemColor: Sendable {
        case windowBackground, controlBackground, quaternaryLabel
        /// A light translucent layer: one step lighter than whatever dark background it sits on.
        case raisedSurface

        #if os(macOS)
        public var nsColor: NSColor {
            switch self {
            case .windowBackground: NSColor.windowBackgroundColor
            case .controlBackground: NSColor.controlBackgroundColor
            case .quaternaryLabel: NSColor.quaternaryLabelColor
            case .raisedSurface: NSColor(white: 1, alpha: 0.08)
            }
        }
        #else
        /// The nearest iOS system colors to the Mac's.
        public var uiColor: UIColor {
            switch self {
            case .windowBackground: UIColor.systemBackground
            case .controlBackground: UIColor.secondarySystemBackground
            case .quaternaryLabel: UIColor.quaternaryLabel
            case .raisedSurface: UIColor(white: 1, alpha: 0.08)
            }
        }
        #endif
    }

    /// `light` (a "#RRGGBB" string) in the light appearance; the system color `dark` in the dark one.
    public static func dynamic(light: String, dark: DarkSystemColor) -> Color {
        let rgb = rgbComponents(hex: light)
        let red = rgb.red
        let green = rgb.green
        let blue = rgb.blue
        #if os(macOS)
        let nsColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return dark.nsColor
            }
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        return Color(nsColor: nsColor)
        #else
        let uiColor = UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return dark.uiColor
            }
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        }
        return Color(uiColor: uiColor)
        #endif
    }

    /// The red, green and blue (0…1) of "#RRGGBB"; gray (0.5) for malformed input.
    public static func rgbComponents(hex: String) -> (red: Double, green: Double, blue: Double) {
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
