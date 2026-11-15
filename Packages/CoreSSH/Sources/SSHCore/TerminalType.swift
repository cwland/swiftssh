/// The terminal type a session announces to the server (`TERM`): Citadel puts it in the PTY request,
/// system ssh passes it on from its own environment. Settings → Terminal → Terminal type.
public enum TerminalType: String, CaseIterable, Codable, Sendable {
    case xterm256color = "xterm-256color"
    case xterm
    case xtermColor = "xterm-color"
    case vt100
    case linux

    /// xterm-256color: what SwiftTerm emulates.
    public static let `default`: TerminalType = .xterm256color
}
