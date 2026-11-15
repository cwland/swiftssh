import SwiftUI
import AppCore

/// The Settings window (Cmd+,): a Termius-style sidebar of panes on the left and the selected
/// pane on the right. New panes are added to AppCore's `SettingsPane` and to `pane(for:)`. The selection
/// lives in `SettingsNavigation`, so other windows can open Settings on a pane.
struct SettingsView: View {
    let connectionSettings: ConnectionSettings
    let terminalSettings: TerminalSettings
    let navigation: SettingsNavigation
    /// App window appearance (System / Light / Dark), per Mac.
    let appearance: AppAppearanceSetting
    let onePassword: OnePasswordSetup
    /// nil until the vault is open.
    let sync: SyncCoordinator?
    /// nil until the vault is open (Sync's join step asks whether to merge this Mac's data).
    let vault: LocalVault?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases, id: \.self) { pane in
                    SettingsSidebarRow(pane: pane, isSelected: navigation.selection == pane) {
                        navigation.selection = pane
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text("Theme")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Picker("Theme", selection: Binding(get: { appearance.appearance },
                                                       set: { appearance.appearance = $0 })) {
                        ForEach(AppAppearance.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .help("Appearance of the app: follow macOS, or always light or dark")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .frame(width: Self.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebarBackground)

            Divider()

            pane(for: navigation.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.contentBackground)
        }
        .frame(minWidth: 960, idealWidth: 1000, minHeight: 560, idealHeight: 720)
    }

    @ViewBuilder
    private func pane(for pane: SettingsPane) -> some View {
        switch pane {
        case .connection: ConnectionSettingsPane(settings: connectionSettings)
        case .terminal: TerminalSettingsPane(settings: terminalSettings)
        case .sync: SyncSettingsPane(sync: sync, vault: vault)
        case .onePassword: OnePasswordSettingsPane(setup: onePassword)
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
