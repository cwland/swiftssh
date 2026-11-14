import AppKit
import AppCore

/// Before the app quits, ends every terminal session (so their connection logs are closed) and
/// waits for queued vault writes, so the last edits are on disk. If the final write fails, asks
/// before quitting so unsaved changes aren't lost silently.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app at launch.
    var environment: AppEnvironment?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A color picked in the last moment is still waiting for its debounced write.
        BadgeLogoStore.shared.flushPendingSave()
        guard let environment, case .ready(let vault) = environment.state else {
            return .terminateNow
        }
        Task { @MainActor in
            await environment.sessions?.closeAll()
            await vault.flush()
            var shouldQuit = true
            if let error = vault.lastSaveError {
                shouldQuit = Self.confirmQuitDespiteSaveError(error)
            }
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    /// Asks whether to quit even though the last vault write failed. Cancel is the default.
    private static func confirmQuitDespiteSaveError(_ error: any Error) -> Bool {
        // The app may be in the background (e.g. quitting from the Dock); bring it forward so
        // the alert is seen.
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some changes couldn't be saved"
        alert.informativeText = "\(error.localizedDescription)\n\nIf you quit now, those changes will be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
