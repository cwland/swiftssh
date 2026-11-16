import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// A saved host: badge, label and "ssh, <username>" subtitle. Selection draws a blue border.
struct HostCardView: View {
    let host: SavedHost
    let subtitle: String
    let isSelected: Bool
    var onEdit: (() -> Void)? = nil

    var body: some View {
        CardRow(title: host.label.isEmpty ? "Untitled host" : host.label, subtitle: subtitle,
                isSelected: isSelected, onEdit: onEdit) {
            BadgeView(badge: host.osBadge, size: Theme.cardBadgeSize, cornerRadius: Theme.cardBadgeCornerRadius)
        }
    }
}
