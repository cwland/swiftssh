import SwiftUI
import AppCore

@main
struct TermiusReimaginedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    appDelegate.environment = environment
                    await environment.load()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
    }
}
