/// Entries in the Settings window's sidebar. Later panes (AI, security)
/// are added here.
public enum SettingsPane: String, CaseIterable, Hashable, Sendable {
    case connection
    case terminal
    case sync
    case onePassword
    case osIcons

    public var title: String {
        switch self {
        case .connection: "Connection"
        case .terminal: "Terminal"
        case .sync: "Sync"
        case .onePassword: "1Password"
        case .osIcons: "OS Icons"
        }
    }

    /// SF Symbol for the sidebar row.
    public var systemImage: String {
        switch self {
        case .connection: "antenna.radiowaves.left.and.right"
        case .terminal: "terminal"
        case .sync: "arrow.triangle.2.circlepath.icloud"
        case .onePassword: "key.horizontal"
        case .osIcons: "square.grid.2x2"
        }
    }
}
