import AppKit
import SwiftUI
import AppCore
import SwiftTerm

// SwiftUI and SwiftTerm both define `Color`; this file always qualifies it.

// Qualified: legacy QuickDraw headers (via AppKit) also declare a C `RGBColor`.
extension AppCore.RGBColor {
    /// sRGB, opaque.
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
    }
}

extension TerminalTheme {
    /// The 16 ANSI colors for `TerminalView.installColors(_:)`.
    var swiftTermPalette: [SwiftTerm.Color] {
        ansi.map(\.swiftTermColor)
    }

}
