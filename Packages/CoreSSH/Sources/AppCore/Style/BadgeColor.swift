import Foundation

/// "#RRGGBB" badge colors: parsing and formatting.
public enum BadgeColor {
    /// `hex` as uppercase "#RRGGBB"; accepts "RRGGBB", "#RRGGBB" and the "#RGB" shorthand
    /// (case-insensitive, surrounding whitespace ignored). nil when it isn't a color.
    public static func normalizedHex(_ hex: String) -> String? {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.first == "#" {
            digits = digits.dropFirst()
        }
        guard digits.allSatisfy(\.isHexDigit), digits.allSatisfy(\.isASCII) else { return nil }
        switch digits.count {
        case 6:
            return "#" + digits.uppercased()
        case 3:
            return "#" + digits.map { "\($0)\($0)" }.joined().uppercased()
        default:
            return nil
        }
    }

    /// Red, green and blue in 0...1, or nil when `hex` isn't a color.
    public static func components(hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let normalized = normalizedHex(hex),
              let value = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    /// "#RRGGBB" from components in 0...1 (clamped, rounded to the nearest step; NaN is 0).
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        "#" + [red, green, blue].map { component -> String in
            let clamped = component.isNaN ? 0 : min(max(component, 0), 1)
            let byte = Int((clamped * 255).rounded())
            let text = String(byte, radix: 16, uppercase: true)
            return text.count == 1 ? "0" + text : text
        }.joined()
    }
}
