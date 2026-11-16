import SwiftUI
import AppCore
import CoreModels

/// A host's OS badge: a colored rounded square with the OS logo or, without one, the catalog's
/// SF Symbol. The Mac app's `BadgeView` feeds it the logo and settings from its Badges folder; the
/// iPhone/iPad app has no logos and uses the standard colors (`init(badge:settings:...)`).
public struct OSBadgeTile: View {
    let hexColor: String
    let symbol: String
    let logo: Image?
    /// Draw the logo as a white template rather than in its own colors.
    let logoInWhite: Bool
    let size: CGFloat
    /// nil scales the standard radius with `size`.
    let cornerRadius: CGFloat?

    public init(hexColor: String, symbol: String, logo: Image? = nil, logoInWhite: Bool = true,
                size: CGFloat = SwiftSSHTheme.badgeSize, cornerRadius: CGFloat? = nil) {
        self.hexColor = hexColor
        self.symbol = symbol
        self.logo = logo
        self.logoInWhite = logoInWhite
        self.size = size
        self.cornerRadius = cornerRadius
    }

    /// The badge for `badge` with no logo: the color from `settings` and the catalog's symbol.
    /// An id the catalog doesn't know gets the grey generic badge.
    public init(badge: OSBadge?, settings: BadgeSettings = BadgeSettings(),
                size: CGFloat = SwiftSSHTheme.badgeSize, cornerRadius: CGFloat? = nil) {
        self.init(hexColor: settings.hexColor(for: badge), symbol: BadgeStyle.symbol(for: badge),
                  size: size, cornerRadius: cornerRadius)
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius ?? SwiftSSHTheme.badgeCornerRadius * size / SwiftSSHTheme.badgeSize,
                         style: .continuous)
            .fill(Color(hex: hexColor))
            .frame(width: size, height: size)
            .overlay {
                if let logo {
                    logo
                        .renderingMode(logoInWhite ? .template : .original)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(Color.white)
                        .padding(size * 0.2)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(Color.white)
                }
            }
    }
}
