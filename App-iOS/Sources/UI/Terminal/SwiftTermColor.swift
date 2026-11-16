import UIKit
import AppCore
import SwiftTerm

// SwiftUI and SwiftTerm both define `Color`; this file always qualifies it. The UIKit and SwiftUI
// colours of a theme come from the shared SwiftSSHUI package (`RGBColor.uiColor`); SwiftTerm's own
// colour type is converted here, because SwiftSSHUI doesn't depend on SwiftTerm.

extension AppCore.RGBColor {
    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
    }
}

extension TerminalTheme {
    /// The 16 ANSI colours for `TerminalView.installColors(_:)`.
    var swiftTermPalette: [SwiftTerm.Color] {
        ansi.map(\.swiftTermColor)
    }
}
