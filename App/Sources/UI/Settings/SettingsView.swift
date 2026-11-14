import SwiftUI
import AppCore

/// The Settings window (Cmd+,): a Termius-style sidebar of panes on the left and the selected
/// pane on the right. New panes are added to `SettingsPane` and to `pane(for:)`.
struct SettingsView: View {
    let connectionSettings: ConnectionSettings
    @State private var selection: SettingsPane = .connection

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases, id: \.self) { pane in
                    SettingsSidebarRow(pane: pane, isSelected: selection == pane) {
                        selection = pane
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .frame(width: Self.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebarBackground)

            Divider()

            pane(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.contentBackground)
        }
        .frame(minWidth: 960, idealWidth: 1000, minHeight: 560, idealHeight: 720)
    }

    @ViewBuilder
    private func pane(for pane: SettingsPane) -> some View {
        switch pane {
        case .connection: ConnectionSettingsPane(settings: connectionSettings)
        case .osIcons: OSIconsSettingsPane()
        }
    }

    private static let sidebarWidth: CGFloat = 200
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.systemImage)
                    .frame(width: 22)
                Text(pane.title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Theme.sidebarRowCornerRadius, style: .continuous)
                    .fill(isSelected ? Theme.sidebarSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
