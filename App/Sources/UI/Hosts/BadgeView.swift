import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// A host's OS badge: a colored rounded square with the logo for that OS (from the Badges
/// folder, set in Settings → OS Icons or dropped in by hand) or, without one, the catalog's SF Symbol.
/// An id the catalog doesn't know gets the grey generic badge.
/// Color and white/original drawing come from the OS Icons settings. Reads through the observable
/// `BadgeLogoStore.shared`, so every badge redraws as soon as a setting or logo changes.
/// The app ships no distro logos. Drawn by the shared `OSBadgeTile`.
struct BadgeView: View {
    let badge: OSBadge?
    var size: CGFloat = Theme.badgeSize
    /// nil scales the standard radius with `size`.
    var cornerRadius: CGFloat?

    var body: some View {
        let store = BadgeLogoStore.shared
        OSBadgeTile(hexColor: store.hexColor(for: badge), symbol: BadgeStyle.symbol(for: badge),
                    logo: store.logo(for: badge).map { Image(nsImage: $0) },
                    logoInWhite: store.showsInWhite(for: badge), size: size, cornerRadius: cornerRadius)
    }
}

extension OSBadge {
    /// Catalog name (the raw id for an OS this build doesn't know).
    var displayName: String {
        BadgeStyle.displayName(for: self)
    }
}
