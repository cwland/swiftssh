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

    /// Folder (inside Application Support/TermiusReimagined) holding optional user-supplied logos.
    public static let logoFolderName = "Badges"

    /// Logo file extensions, in order of preference.
    public static let logoFileExtensions = ["svg", "png"]

    /// Base file name (without extension) of the optional user-supplied logo for a badge.
    public static func logoFileName(for badge: OSBadge) -> String {
        switch badge {
        case .ubuntu: "ubuntu"
        case .debian: "debian"
        case .raspberryPiOS: "raspberry-pi"
        case .fedora: "fedora"
        case .rhel: "rhel"
        case .alpine: "alpine"
        case .arch: "arch"
        case .macOS: "macos"
        case .freeBSD: "freebsd"
        case .linux: "linux"
        case .synology: "synology"
        case .homeAssistant: "home-assistant"
        }
    }

    /// File name of a logo installed from Settings (always PNG).
    public static func installedLogoFileName(for badge: OSBadge) -> String {
        logoFileName(for: badge) + ".png"
    }

    /// Every file name the app reads as the logo for `badge`, in order of preference.
    public static func logoFileNames(for badge: OSBadge) -> [String] {
        logoFileExtensions.map { logoFileName(for: badge) + "." + $0 }
    }

    /// Per-OS appearance settings inside the Badges folder (see `BadgeSettings`).
    public static let settingsFileName = "settings.json"

    /// Rows of Settings → OS Icons, in order.
    public static let settingsOrder: [OSBadge] = [
        .ubuntu, .debian, .raspberryPiOS, .fedora, .rhel, .alpine, .arch, .macOS, .freeBSD, .linux,
        .synology, .homeAssistant,
    ]

    /// Row name in Settings → OS Icons.
    public static func settingsName(for badge: OSBadge) -> String {
        switch badge {
        case .ubuntu: "Ubuntu"
        case .debian: "Debian"
        case .raspberryPiOS: "Raspberry Pi"
        case .fedora: "Fedora"
        case .rhel: "RHEL"
        case .alpine: "Alpine"
        case .arch: "Arch"
        case .macOS: "macOS"
        case .freeBSD: "FreeBSD"
        case .linux: "Linux"
        case .synology: "Synology"
        case .homeAssistant: "Home Assistant"
        }
    }
}
