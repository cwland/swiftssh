/// Entries in the Settings window's sidebar. Later panes (terminal themes, sync, AI, security)
/// are added here.
public enum SettingsPane: String, CaseIterable, Hashable, Sendable {
    case osIcons

    public var title: String {
        switch self {
        case .osIcons: "OS Icons"
        }
    }

    /// SF Symbol for the sidebar row.
    public var systemImage: String {
        switch self {
        case .osIcons: "square.grid.2x2"
        }
    }
}
