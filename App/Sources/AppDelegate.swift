import AppKit
import AppCore

/// Waits for queued vault writes before the app quits, so the last edits are on disk.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app at launch.
    var environment: AppEnvironment?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment, case .ready(let vault) = environment.state else {
            return .terminateNow
        }
        Task { @MainActor in
            await vault.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
