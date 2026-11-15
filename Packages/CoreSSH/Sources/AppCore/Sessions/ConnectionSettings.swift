import Foundation
import Observation
import SSHCore

/// Settings → Connection → "Detect dropped connections".
public enum DroppedConnectionDetection: String, CaseIterable, Codable, Sendable {
    case fast, normal, relaxed, off

    public var title: String {
        switch self {
        case .fast: "Fast"
        case .normal: "Normal"
        case .relaxed: "Relaxed"
        case .off: "Off"
        }
    }

    public var detail: String {
        switch self {
        case .fast: "Checks every 15 seconds. A dropped connection shows up in about 30–45 seconds."
        case .normal: "Checks every 30 seconds. A dropped connection shows up in about 1½–2 minutes. Recommended."
        case .relaxed: "Checks every 60 seconds. A dropped connection shows up in about 5–6 minutes. For shaky Wi-Fi."
        case .off: "Never checks. A dead connection can go unnoticed for a long time."
        }
    }

    public var policy: KeepAlivePolicy {
        switch self {
        case .fast: .fast
        case .normal: .normal
        case .relaxed: .relaxed
        case .off: .off
        }
    }
}

/// Connection preferences, stored per Mac in UserDefaults (never synced).
@MainActor @Observable
public final class ConnectionSettings {
    static let detectionKey = "connection.droppedConnectionDetection"
    static let autoReconnectKey = "connection.autoReconnect"
    static let askToSaveWorkspacesKey = "workspaces.askToSaveOnClose"

    @ObservationIgnored private let defaults: UserDefaults

    public var detection: DroppedConnectionDetection {
        didSet { defaults.set(detection.rawValue, forKey: Self.detectionKey) }
    }

    /// "Reconnect automatically": after a dropped connection, try again on the `ReconnectSchedule`.
    public var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: Self.autoReconnectKey) }
    }

    /// "Ask to save workspaces when closing": closing a workspace with unsaved changes asks Save / Don't
    /// Save / Cancel first.
    public var askToSaveWorkspaces: Bool {
        didSet { defaults.set(askToSaveWorkspaces, forKey: Self.askToSaveWorkspacesKey) }
    }

    /// A missing or unknown stored detection is `.normal`; missing auto-reconnect and ask-to-save
    /// choices are on.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        detection = defaults.string(forKey: Self.detectionKey).flatMap(DroppedConnectionDetection.init(rawValue:)) ?? .normal
        autoReconnect = defaults.object(forKey: Self.autoReconnectKey) as? Bool ?? true
        askToSaveWorkspaces = defaults.object(forKey: Self.askToSaveWorkspacesKey) as? Bool ?? true
    }
}
