import SwiftUI
import AppCore

struct SidebarView: View {
    let navigation: AppNavigation
    /// For the count beside each section.
    let vault: LocalVault

    var body: some View {
        // Counted once per render (one pass over the vault), not once per row.
        let counts = SidebarCounts(vault: vault)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarItem.allCases, id: \.self) { item in
                SidebarRow(item: item, count: counts.count(for: item),
                           isSelected: navigation.sidebar == item) {
                    navigation.sidebar = item
                }
            }
            Spacer(minLength: 0)
            Text(AppVersion.display)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBackground)
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    /// nil: no number.
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .frame(width: 24)
                Text(item.title)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: Theme.sidebarFontSize))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.sidebarRowCornerRadius, style: .continuous)
                    .fill(isSelected ? Theme.sidebarSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(item.title), \($0)" } ?? item.title)
    }
}

extension SidebarItem {
    var title: String {
        switch self {
        case .hosts: "Hosts"
        case .keychain: "Keychain"
        case .snippets: "Snippets"
        case .knownHosts: "Known Hosts"
        case .logs: "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .hosts: "server.rack"
        case .keychain: "key"
        case .snippets: "curlybraces"
        case .knownHosts: "checkmark.shield"
        case .logs: "clock.arrow.circlepath"
        }
    }
}
