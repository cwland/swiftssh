import SwiftUI
import SwiftSSHUI

/// The shared look, by the name the Mac app uses.
typealias Theme = SwiftSSHTheme

/// SwiftSSH for iPhone and iPad: a connect-only companion to the Mac app. It joins the Mac's sync
/// server and connects to the synced hosts; everything is set up on the Mac.
@main
struct SwiftSSHMobileApp: App {
    @State private var environment = IOSEnvironment()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(environment)
                .tint(Theme.accent)
                .task { await environment.load() }
        }
        .commands {
            CompanionCommands(environment: environment)
        }
    }
}
