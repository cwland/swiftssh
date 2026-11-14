import SwiftUI
import AppCore
import CoreModels

/// A saved host: badge, label and "ssh, <username>" subtitle. Selection draws a blue border.
struct HostCardView: View {
    let host: SavedHost
    let subtitle: String
    let isSelected: Bool

    var body: some View {
        CardRow(title: host.label.isEmpty ? "Untitled host" : host.label, subtitle: subtitle,
                isSelected: isSelected) {
            BadgeView(badge: host.osBadge, size: Theme.cardBadgeSize, cornerRadius: Theme.cardBadgeCornerRadius)
        }
    }
}
