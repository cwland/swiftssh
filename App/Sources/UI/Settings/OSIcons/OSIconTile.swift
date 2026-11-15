import SwiftUI
import AppCore
import CoreModels

/// One OS in the Settings → OS Icons grid: its badge and name. Clicking opens that OS's popup.
struct OSIconTile: View {
    let entry: OSCatalog.Entry
    let store: BadgeLogoStore
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                BadgeView(badge: entry.id, size: 48, cornerRadius: Theme.cardBadgeCornerRadius + 2)
                    .overlay(alignment: .topTrailing) {
                        if store.isWorking(entry.id) {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(3)
                                .background(.regularMaterial, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isHovering ? 0.6 : 0), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(entry.name)
        .accessibilityHint("Opens this OS's icon settings")
    }
}
