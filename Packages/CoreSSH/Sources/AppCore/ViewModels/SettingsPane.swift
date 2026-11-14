/// Entries in the Settings window's sidebar. Later panes (terminal themes, sync, AI, security)
/// are added here.
public enum SettingsPane: String, CaseIterable, Hashable, Sendable {
    case connection
    case onePassword
    case osIcons

    public var title: String {
        switch self {
        case .connection: "Connection"
        case .onePassword: "1Password"
        case .osIcons: "OS Icons"
        }
    }

    /// SF Symbol for the sidebar row.
    public var systemImage: String {
        switch self {
        case .connection: "antenna.radiowaves.left.and.right"
        case .onePassword: "key.horizontal"
        case .osIcons: "square.grid.2x2"
        }
    }
}
