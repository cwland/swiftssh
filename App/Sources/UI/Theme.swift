import SwiftUI
import AppKit

/// Visual Reference tokens. The top bar stays navy in both appearances; content and sidebar
/// follow the system appearance.
enum Theme {
    // Top bar
    static let topBarBackground = Color(hex: "#23263A")
    static let tabBackground = Color(hex: "#2F3348")
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
    static let cardBackground = Color.dynamic(light: "#FFFFFF", dark: .controlBackground)
    static let cardCornerRadius: CGFloat = 14
    static let cardHeight: CGFloat = 96
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

        var nsColor: NSColor {
            switch self {
            case .windowBackground: NSColor.windowBackgroundColor
            case .controlBackground: NSColor.controlBackgroundColor
            case .quaternaryLabel: NSColor.quaternaryLabelColor
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
