import Foundation

/// A host's operating system, as the id of an entry in the app's OS catalog (AppCore `OSCatalog`),
/// e.g. "ubuntu", "raspbian", "proxmox". Stored in synced `Host` records as that string.
///
/// Any string decodes, so a record written by a newer build with an id this build doesn't know
/// still loads and round-trips unchanged (it is drawn as a generic badge). The raw values written
/// by the old fixed list (`raspberryPiOS`, `macOS`, `freeBSD`, `homeAssistant`) are read as their
/// catalog ids; every value is written as the catalog id.
public struct OSBadge: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Old enum raw values whose catalog id differs.
    public static let legacyRawValues: [String: String] = [
        "raspberryPiOS": "raspbian",
        "macOS": "macos",
        "freeBSD": "freebsd",
        "homeAssistant": "home-assistant",
    ]

    public init(rawValue: String) {
        self.rawValue = Self.legacyRawValues[rawValue] ?? rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    // The ids the old fixed list could store (more ids live in AppCore, next to the catalog).
    public static let ubuntu = OSBadge(rawValue: "ubuntu")
    public static let debian = OSBadge(rawValue: "debian")
    public static let raspbian = OSBadge(rawValue: "raspbian")
    public static let fedora = OSBadge(rawValue: "fedora")
    public static let rhel = OSBadge(rawValue: "rhel")
    public static let alpine = OSBadge(rawValue: "alpine")
    public static let arch = OSBadge(rawValue: "arch")
    public static let macos = OSBadge(rawValue: "macos")
    public static let freebsd = OSBadge(rawValue: "freebsd")
    public static let linux = OSBadge(rawValue: "linux")
    public static let synology = OSBadge(rawValue: "synology")
    public static let homeAssistant = OSBadge(rawValue: "home-assistant")
}
