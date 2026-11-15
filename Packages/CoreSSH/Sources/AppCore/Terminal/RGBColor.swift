import Foundation

/// An sRGB color with 8-bit components, as terminal themes define them.
public struct RGBColor: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#RRGGBB" or "RRGGBB", any case, surrounding whitespace ignored. Anything else → nil.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.utf8.count == 6, digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// "#RRGGBB", uppercase.
    public var hex: String {
        "#" + [red, green, blue].map { byte in
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    /// WCAG 2 relative luminance, 0…1.
    public var relativeLuminance: Double {
        func linear(_ component: UInt8) -> Double {
            let c = Double(component) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, 1…21.
    public func contrastRatio(with other: RGBColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
