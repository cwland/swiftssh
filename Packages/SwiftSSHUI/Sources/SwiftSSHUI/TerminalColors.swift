import SwiftUI
import AppCore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// Terminal theme colors as SwiftUI and platform colors. Qualified `AppCore.RGBColor`: legacy
// QuickDraw headers (via AppKit) also declare a C `RGBColor`.
extension AppCore.RGBColor {
    /// sRGB, opaque.
    public var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    #if os(macOS)
    /// sRGB, opaque.
    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    #else
    /// sRGB, opaque.
    public var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    #endif
}
