import SwiftUI
import Observation
import AppCore

/// The Settings window's selected pane, shared so other windows can open Settings on a pane.
@MainActor @Observable
final class SettingsNavigation {
    var selection: SettingsPane = .connection
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
