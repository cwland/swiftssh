import SwiftUI
import Observation
import AppCore

/// The Settings window's sidebar entries. Mirrors AppCore's `SettingsPane` and adds 1Password
/// (after Connection) in the app layer, since AppCore isn't changed by this feature.
/// Core follow-up: add `.onePassword` to `SettingsPane` and drop this enum.
enum AppSettingsPane: String, CaseIterable, Hashable {
    case connection
    case onePassword
    case osIcons

    var title: String {
        switch self {
        case .connection: SettingsPane.connection.title
        case .onePassword: "1Password"
        case .osIcons: SettingsPane.osIcons.title
        }
    }

    /// SF Symbol for the sidebar row.
    var systemImage: String {
        switch self {
        case .connection: SettingsPane.connection.systemImage
        case .onePassword: "key.horizontal"
        case .osIcons: SettingsPane.osIcons.systemImage
        }
    }
}

/// The Settings window's selected pane, shared so other windows can open Settings on a pane.
@MainActor @Observable
final class SettingsNavigation {
    var selection: AppSettingsPane = .connection
}

/// "Open 1Password Setup": selects Settings → 1Password and opens (or brings forward) Settings.
/// Needs `SettingsNavigation` in the environment; without it, Settings opens on its last pane.
struct OpenOnePasswordSetupButton: View {
    var title = "Open 1Password Setup"
    /// Runs first, e.g. to close a sheet.
    var before: () -> Void = {}

    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            before()
            navigation?.selection = .onePassword
            openSettings()
        }
        .help("Settings \u{2192} 1Password")
    }
}
