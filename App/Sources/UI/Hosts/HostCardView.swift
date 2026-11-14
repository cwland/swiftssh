import SwiftUI
import AppCore
import CoreModels

/// A saved host: badge, label and "ssh, <username>" subtitle. Selection draws a blue border.
struct HostCardView: View {
    let host: SavedHost
    let subtitle: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            BadgeView(badge: host.osBadge)
            VStack(alignment: .leading, spacing: 4) {
                Text(host.label.isEmpty ? "Untitled host" : host.label)
                    .font(.system(size: 19))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
    }
}
