import SwiftUI
import AppCore

struct SidebarView: View {
    let navigation: AppNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarItem.allCases, id: \.self) { item in
                SidebarRow(item: item, isSelected: navigation.sidebar == item) {
                    navigation.sidebar = item
                }
            }
            Spacer(minLength: 0)
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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .frame(width: 24)
                Text(item.title)
                Spacer(minLength: 0)
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
