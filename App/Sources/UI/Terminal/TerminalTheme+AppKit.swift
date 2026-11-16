import AppKit
import SwiftUI
import AppCore
import SwiftTerm
import SwiftSSHUI

// SwiftUI and SwiftTerm both define `Color`; this file always qualifies it.
// `RGBColor.nsColor` and `RGBColor.swiftUIColor` are in the shared SwiftSSHUI package.

// Qualified: legacy QuickDraw headers (via AppKit) also declare a C `RGBColor`.
extension AppCore.RGBColor {
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
