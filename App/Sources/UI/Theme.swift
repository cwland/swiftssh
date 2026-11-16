import SwiftUI
import AppKit
import AppCore
import SwiftSSHUI

/// Visual Reference tokens, cards and badges live in the shared `SwiftSSHUI` package (the
/// iPhone/iPad app uses it too); `Theme` keeps the Mac app's call sites unchanged.
typealias Theme = SwiftSSHTheme

extension Color {
    /// "#RRGGBB" of this color in sRGB, nil if it can't be converted (e.g. a pattern color).
    var sRGBHex: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return BadgeColor.hex(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                              blue: Double(srgb.blueComponent))
    }
}
