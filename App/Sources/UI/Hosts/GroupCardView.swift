import SwiftUI
import AppCore
import CoreModels

/// A host group: folder symbol, name and "N hosts".
struct GroupCardView: View {
    let group: HostGroup
    let hostCount: Int

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: Theme.badgeCornerRadius, style: .continuous)
                .fill(Theme.accent.opacity(0.15))
                .frame(width: Theme.badgeSize, height: Theme.badgeSize)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name.isEmpty ? "Untitled group" : group.name)
                    .font(.system(size: 19))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(hostCount == 1 ? "1 host" : "\(hostCount) hosts")
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
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
    }
}
