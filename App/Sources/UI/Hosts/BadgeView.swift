import SwiftUI
import AppCore
import CoreModels

/// A host's OS badge: a generic SF Symbol in a colored rounded square (never a distro logo).
struct BadgeView: View {
    let badge: OSBadge?
    var size: CGFloat = Theme.badgeSize

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.badgeCornerRadius * size / Theme.badgeSize, style: .continuous)
            .fill(Color(hex: BadgeStyle.hexColor(for: badge)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: BadgeStyle.symbol(for: badge))
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Color.white)
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
