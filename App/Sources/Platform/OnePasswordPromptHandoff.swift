import AppKit
import AppCore

/// The AppKit side of `OnePasswordPromptFocus`: brings 1Password forward while its Touch ID /
/// approval prompt is showing, and this app back afterwards.
enum OnePasswordApp {
    /// 1Password 8, and 1Password 7 for older setups.
    static let bundleIDs: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7"]

    /// Lets 1Password take the focus (macOS only allows an app to activate another this way). Only
    /// while this app is the active one: if the user is in another app, nothing is handed over (false).
    /// Also only while 1Password shows a prompt: a call that is merely slow (a big account, a far-away
    /// server) must not bring 1Password's main window forward. The coordinator asks again shortly.
    @MainActor static func handOff() -> Bool {
        guard NSApp.isActive, let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier.map(bundleIDs.contains) == true
        }), showsPrompt(app) else { return false }
        NSApp.yieldActivation(to: app)
        return app.activate()
    }

    /// Whether `app` has an on-screen window that looks like its approval / Touch ID prompt: a floating
    /// one (layer above normal windows) or a small one. Owner and bounds need no screen-recording
    /// permission.
    @MainActor static func showsPrompt(_ app: NSRunningApplication) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier else { return false }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let bounds = (window[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return layer > 0 || (bounds.width > 0 && bounds.width <= 640 && bounds.height <= 520)
        }
    }

    /// Only while 1Password is still the frontmost app: if the user moved on to another app, stay out
    /// of the way.
    @MainActor static func takeBack() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier.map(bundleIDs.contains) == true else { return }
        NSApp.activate()
    }

    /// The session manager being watched; a newer one (the vault opened again) ends the old chain.
    @MainActor private static var watched: ObjectIdentifier?

    /// Follows every tab's connection log: one wait while any connecting tab is signing with
    /// 1Password's agent. Re-arms itself after each change (Observation).
    @MainActor static func watchAgentSigning(_ sessions: SessionManager, focus: OnePasswordPromptFocus) {
        watched = ObjectIdentifier(sessions)
        observe(sessions, focus: focus)
    }

    @MainActor private static func observe(_ sessions: SessionManager, focus: OnePasswordPromptFocus) {
        let waiting = withObservationTracking {
            sessions.tabs.contains {
                $0.state == .connecting && OnePasswordPromptFocus.isWaitingForAgent($0.connectionLog)
            }
        } onChange: { [weak sessions, weak focus] in
            Task { @MainActor in
                guard let sessions, let focus, watched == ObjectIdentifier(sessions) else { return }
                observe(sessions, focus: focus)
            }
        }
        focus.setAgentWaiting(waiting)
    }
}

/// An `op` client whose every call counts as a wait for 1Password (it may show its unlock prompt).
struct FocusHandingOnePasswordCLI: OnePasswordCLI {
    let base: any OnePasswordCLI
    let focus: OnePasswordPromptFocus

    func read(reference: String) async throws(OnePasswordError) -> String {
        try await waiting { () async throws(OnePasswordError) in try await base.read(reference: reference) }
    }

    func listItems() async throws(OnePasswordError) -> [OnePasswordItemSummary] {
        try await waiting { () async throws(OnePasswordError) in try await base.listItems() }
    }

    func fields(itemID: String, vault: String) async throws(OnePasswordError) -> [OnePasswordField] {
        try await waiting { () async throws(OnePasswordError) in try await base.fields(itemID: itemID, vault: vault) }
    }

    func check() async throws(OnePasswordError) {
        try await waiting { () async throws(OnePasswordError) in try await base.check() }
    }

    private func waiting<T: Sendable>(_ work: () async throws(OnePasswordError) -> T) async throws(OnePasswordError) -> T {
        await focus.beginWait()
        let result: Result<T, OnePasswordError>
        do { result = .success(try await work()) } catch { result = .failure(error) }
        await focus.endWait()
        return try result.get()
    }
}
