import Foundation
import Observation
import SSHCore

/// Connection preferences, stored per Mac in UserDefaults (never synced).
@MainActor @Observable
public final class ConnectionSettings {
    static let autoReconnectKey = "connection.autoReconnect"
    static let askToSaveWorkspacesKey = "workspaces.askToSaveOnClose"

    @ObservationIgnored private let defaults: UserDefaults

    /// How often sessions check that the server still answers. Fixed: there is nothing to tune (an
    /// older "Detect dropped connections" choice, if stored, is ignored).
    public var keepAlivePolicy: KeepAlivePolicy { .standard }

    /// "Reconnect automatically": after a dropped connection, try again on the `ReconnectSchedule`.
    public var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: Self.autoReconnectKey) }
    }

    /// "Ask to save workspaces when closing": closing a workspace with unsaved changes asks Save / Don't
    /// Save / Cancel first.
    public var askToSaveWorkspaces: Bool {
        didSet { defaults.set(askToSaveWorkspaces, forKey: Self.askToSaveWorkspacesKey) }
    }

    /// Missing auto-reconnect and ask-to-save choices are on.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoReconnect = defaults.object(forKey: Self.autoReconnectKey) as? Bool ?? true
        askToSaveWorkspaces = defaults.object(forKey: Self.askToSaveWorkspacesKey) as? Bool ?? true
    }
}
