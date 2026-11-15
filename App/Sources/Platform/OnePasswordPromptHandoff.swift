import AppKit
import AppCore

/// The AppKit side of `OnePasswordPromptFocus`: brings 1Password forward while its Touch ID /
/// approval prompt is showing, and this app back afterwards.
enum OnePasswordApp {
    /// 1Password 8, and 1Password 7 for older setups.
    static let bundleIDs: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7"]

    /// Lets 1Password take the focus (macOS only allows an app to activate another this way).
    @MainActor static func handOff() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier.map(bundleIDs.contains) == true
        }) else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// Only while 1Password is still the frontmost app: if the user moved on to another app, stay out
    /// of the way.
    @MainActor static func takeBack() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier.map(bundleIDs.contains) == true else { return }
        NSApp.activate()
    }

    /// Follows every tab's connection log: one wait while any tab is signing with 1Password's agent.
    /// Re-arms itself after each change (Observation).
    @MainActor static func watchAgentSigning(_ sessions: SessionManager, focus: OnePasswordPromptFocus) {
        let waiting = withObservationTracking {
            sessions.tabs.contains { OnePasswordPromptFocus.isWaitingForAgent($0.connectionLog) }
        } onChange: { [weak sessions, weak focus] in
            Task { @MainActor in
                guard let sessions, let focus else { return }
                watchAgentSigning(sessions, focus: focus)
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
