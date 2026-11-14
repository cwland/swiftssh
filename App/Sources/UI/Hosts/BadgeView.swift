import SwiftUI
import AppCore
import CoreModels

/// A host's OS badge: a colored rounded square with the logo for that OS (from the Badges
/// folder, set in Settings → OS Icons or dropped in by hand) or, without one, a generic SF Symbol.
/// Color and white/original drawing come from the OS Icons settings. Reads through the observable
/// `BadgeLogoStore.shared`, so every badge redraws as soon as a setting or logo changes.
/// The app ships no distro logos.
struct BadgeView: View {
    let badge: OSBadge?
    var size: CGFloat = Theme.badgeSize
    /// nil scales the standard radius with `size`.
    var cornerRadius: CGFloat?

    var body: some View {
        let store = BadgeLogoStore.shared
        RoundedRectangle(cornerRadius: cornerRadius ?? Theme.badgeCornerRadius * size / Theme.badgeSize, style: .continuous)
            .fill(Color(hex: store.hexColor(for: badge)))
            .frame(width: size, height: size)
            .overlay {
                if let logo = store.logo(for: badge) {
                    Image(nsImage: logo)
                        .renderingMode(store.showsInWhite(for: badge) ? .template : .original)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(Color.white)
                        .padding(size * 0.2)
                } else {
                    Image(systemName: BadgeStyle.symbol(for: badge))
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(Color.white)
                }
            }
    }
}

extension OSBadge {
    var displayName: String {
        switch self {
        case .ubuntu: "Ubuntu"
        case .debian: "Debian"
        case .raspberryPiOS: "Raspberry Pi OS"
        case .fedora: "Fedora"
        case .rhel: "RHEL"
        case .alpine: "Alpine"
        case .arch: "Arch"
        case .macOS: "macOS"
        case .freeBSD: "FreeBSD"
        case .linux: "Linux"
        case .synology: "Synology"
        case .homeAssistant: "Home Assistant"
        }
    }
}
