import Foundation
import CoreModels

/// Per-OS badge appearance chosen in Settings → OS Icons: whether the logo is drawn as a white
/// template and an optional badge color. Stored locally (never synced) as
/// `Badges/settings.json`, keyed by the badge's logo file name:
///
///     { "version": 1, "badges": { "ubuntu": { "showInWhite": false, "color": "#E2602F" } } }
///
/// Badges left at their defaults are not written. Unknown keys, unknown badges and malformed
/// colors are ignored when reading.
public struct BadgeSettings: Equatable, Sendable {
    public struct Appearance: Equatable, Sendable {
        /// Draw the logo as a white template on the colored square (default) or in its own colors.
        public var showsInWhite = true
        /// "#RRGGBB" override; nil uses `BadgeStyle.hexColor(for:)`.
        public var hexColor: String?

        public init(showsInWhite: Bool = true, hexColor: String? = nil) {
            self.showsInWhite = showsInWhite
            self.hexColor = hexColor
        }

        var isDefault: Bool { showsInWhite && hexColor == nil }
    }

    public static let currentVersion = 1

    private var appearances: [OSBadge: Appearance] = [:]

    public init() {}

    public func showsInWhite(for badge: OSBadge?) -> Bool {
        badge.flatMap { appearances[$0]?.showsInWhite } ?? true
    }

    /// The badge background: the override when set, otherwise the standard color.
    public func hexColor(for badge: OSBadge?) -> String {
        badge.flatMap { appearances[$0]?.hexColor } ?? BadgeStyle.hexColor(for: badge)
    }

    /// True when the color or the white setting differs from the defaults.
    public func hasCustomAppearance(for badge: OSBadge) -> Bool {
        appearances[badge] != nil
    }

    public mutating func setShowsInWhite(_ showsInWhite: Bool, for badge: OSBadge) {
        update(badge) { $0.showsInWhite = showsInWhite }
    }

    /// Sets the color override; the standard color clears it, and a malformed value is ignored.
    public mutating func setColor(_ hex: String, for badge: OSBadge) {
        guard let normalized = BadgeColor.normalizedHex(hex) else { return }
        update(badge) {
            $0.hexColor = normalized == BadgeStyle.hexColor(for: badge) ? nil : normalized
        }
    }

    /// Back to white and the standard color.
    public mutating func reset(_ badge: OSBadge) {
        appearances[badge] = nil
    }

    private mutating func update(_ badge: OSBadge, _ change: (inout Appearance) -> Void) {
        var appearance = appearances[badge] ?? Appearance()
        change(&appearance)
        appearances[badge] = appearance.isDefault ? nil : appearance
    }

    // MARK: JSON

    private struct FileFormat: Codable {
        var version: Int?
        var badges: [String: Entry]?
    }

    private struct Entry: Codable {
        var showInWhite: Bool?
        var color: String?
    }

    /// Reads `settings.json`. Throws only when the data isn't a JSON object of this shape.
    public init(jsonData: Data) throws {
        let file = try JSONDecoder().decode(FileFormat.self, from: jsonData)
        for (name, entry) in file.badges ?? [:] {
            guard let badge = OSBadge.allCases.first(where: { BadgeStyle.logoFileName(for: $0) == name }) else {
                continue
            }
            if let showInWhite = entry.showInWhite {
                setShowsInWhite(showInWhite, for: badge)
            }
            if let color = entry.color {
                setColor(color, for: badge)
            }
        }
    }

    /// Pretty-printed with sorted keys, so the file diffs and reads well.
    public func jsonData() throws -> Data {
        var badges: [String: Entry] = [:]
        for (badge, appearance) in appearances {
            badges[BadgeStyle.logoFileName(for: badge)] = Entry(showInWhite: appearance.showsInWhite,
                                                                 color: appearance.hexColor)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(FileFormat(version: Self.currentVersion, badges: badges))
    }
}
