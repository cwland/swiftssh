import CoreModels

public enum BadgeStyle {
    /// SF Symbol name for a host's OS badge.
    public static func symbol(for badge: OSBadge?) -> String {
        switch badge {
        case .none, .ubuntu, .debian, .fedora, .rhel, .alpine, .arch, .linux: "terminal"
        case .raspberryPiOS: "cpu"
        case .macOS: "desktopcomputer"
        case .freeBSD: "server.rack"
        case .synology: "externaldrive.connected.to.line.below"
        case .homeAssistant: "house"
        }
    }

    /// Badge background as "#RRGGBB".
    public static func hexColor(for badge: OSBadge?) -> String {
        switch badge {
        case .ubuntu: "#E2602F"
        case .debian, .raspberryPiOS: "#C2275A"
        case .macOS: "#111111"
        case .synology: "#1F4A7A"
        case .homeAssistant: "#2C5D84"
        case .none, .fedora, .rhel, .alpine, .arch, .freeBSD, .linux: "#5B6475"
        }
    }
}
