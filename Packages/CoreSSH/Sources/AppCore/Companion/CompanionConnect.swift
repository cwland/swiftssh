import Foundation
import CoreModels
import SSHCore

/// Connecting on iPhone/iPad, around `SessionManager`: which hosts need the keys imported on the device
/// (reading them asks for Face ID, so the app asks first, off the main thread's critical path), and
/// what the password prompt offers to iOS AutoFill.
public enum CompanionConnect {
    /// Whether connecting to the host reads the imported keys: it signs in with a 1Password SSH key
    /// (on the host or its identity). False for every other host, and for one that can't connect
    /// anyway (missing, no address…), so those never ask for Face ID.
    @MainActor
    public static func needsImportedKeys(hostID: UUID, vault: LocalVault) -> Bool {
        do {
            _ = try ConnectionPlanner.plan(hostID: hostID, vault: vault, platform: .ios, importedKeys: [])
            return false
        } catch ConnectionPlanError.noImportedKeys {
            return true
        } catch {
            return false
        }
    }

    /// What the password prompt gives AutoFill: the username (so iOS offers matching logins) and,
    /// when the Mac reads this password from 1Password, a hint naming the item.
    public struct PasswordPrompt: Equatable, Sendable {
        public let username: String?
        public let onePasswordHint: String?
    }

    /// For a saved host (nil = quick connect: nothing known).
    @MainActor
    public static func passwordPrompt(hostID: UUID?, vault: LocalVault) -> PasswordPrompt {
        guard let hostID, let host = vault.get(SavedHost.self, id: hostID) else {
            return PasswordPrompt(username: nil, onePasswordHint: nil)
        }
        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        let resolved = CredentialResolution.resolve(host: host, directory: directory, vault: vault)
        var hint: String?
        if let password = resolved.password, SecretReference.isReference(password) {
            let item = SecretReference.itemName(password).map { " (\u{201C}\($0)\u{201D})" } ?? ""
            hint = "On your Mac this password comes from 1Password\(item). Choose that login from AutoFill above the keyboard."
        }
        return PasswordPrompt(username: resolved.username, onePasswordHint: hint)
    }
}

/// What a session tab shows, from its state (the same rules as the Mac's terminal tab): the
/// connection screen (steps, then the log on failure) while connecting and after an attempt that
/// never got in, during automatic reconnect tries, or the terminal with a banner once a live
/// session dropped.
public enum TerminalTabPresentation {
    /// Connecting, asking, a first attempt that failed, an automatic try (or the countdown after a
    /// failed one), or auto-reconnect gave up. A tab that was live keeps its terminal otherwise.
    public static func showsConnectionScreen(state: TerminalTab.State, autoReconnect: AutoReconnectState?,
                                             hadLiveSession: Bool) -> Bool {
        switch autoReconnect {
        case .reconnecting, .gaveUp: return true
        case .waiting(let attempt, _, _): if attempt > 1 { return true }
        case nil: break
        }
        switch state {
        case .connecting, .awaitingHostKey, .awaitingPassword: return true
        case .disconnected: return !hadLiveSession
        case .connected: return false
        }
    }

    /// The disconnected banner over the terminal: the reason, or "Connection closed"; nil = none
    /// (connected, auto-reconnecting, or the connection screen shows instead).
    public static func banner(state: TerminalTab.State, autoReconnect: AutoReconnectState?,
                              hadLiveSession: Bool) -> String? {
        guard case .disconnected(let message) = state, autoReconnect == nil,
              !showsConnectionScreen(state: state, autoReconnect: autoReconnect, hadLiveSession: hadLiveSession)
        else { return nil }
        return message ?? "Connection closed"
    }
}
