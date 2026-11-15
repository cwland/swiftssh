import Foundation
import CoreModels

/// Per-OS badge settings chosen in Settings → OS Icons: whether the logo is drawn as a white
/// template, an optional badge color, an optional icon link (instead of the catalog's default)
/// and the link the current image was downloaded from. Stored locally (never synced) as
/// `Badges/settings.json`, keyed by catalog id:
///
///     { "version": 2, "badges": { "ubuntu": { "showInWhite": false, "color": "#E2602F",
///                                             "link": "https://…", "source": "https://…" } } }
///
/// Entries left at their defaults are not written. Reading is lenient: each field is read on its
/// own, so a bad value drops only that value; unknown ids, unknown keys, bad colors and links that
/// aren't http(s) are ignored. Version 1 keys (`raspberry-pi`) are read as their catalog id.
public struct BadgeSettings: Equatable, Sendable {
    public struct Appearance: Equatable, Sendable {
        /// Draw the logo as a white template on the colored square (default) or in its own colors.
        public var showsInWhite = true
        /// "#RRGGBB" override; nil uses `BadgeStyle.hexColor(for:)`.
        public var hexColor: String?
        /// Icon link override; nil uses the catalog's default link.
        public var link: String?
        /// The link the installed image was downloaded from; nil for a file or no image.
        public var imageSource: String?

        public init(showsInWhite: Bool = true, hexColor: String? = nil, link: String? = nil, imageSource: String? = nil) {
            self.showsInWhite = showsInWhite
            self.hexColor = hexColor
            self.link = link
            self.imageSource = imageSource
        }

        var isDefault: Bool { showsInWhite && hexColor == nil && link == nil && imageSource == nil }
    }

    public static let currentVersion = 2

    private var appearances: [OSBadge: Appearance] = [:]

    public init() {}

    public func showsInWhite(for badge: OSBadge?) -> Bool {
        badge.flatMap { appearances[$0]?.showsInWhite } ?? true
    }

    /// The badge background: the override when set, otherwise the standard color.
    public func hexColor(for badge: OSBadge?) -> String {
        badge.flatMap { appearances[$0]?.hexColor } ?? BadgeStyle.hexColor(for: badge)
    }

    /// The icon link shown in Settings: the override, else the catalog default ("" if none).
    public func link(for badge: OSBadge) -> String {
        appearances[badge]?.link ?? OSCatalog.shared.entry(for: badge)?.defaultLink ?? ""
    }

    public func hasCustomLink(for badge: OSBadge) -> Bool {
        appearances[badge]?.link != nil
    }

    /// Where the current image came from, when it was downloaded.
    public func imageSource(for badge: OSBadge) -> String? {
        appearances[badge]?.imageSource
    }

    /// True when anything differs from the defaults (color, white, link or a remembered source).
    public func hasCustomSettings(for badge: OSBadge) -> Bool {
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

    /// Sets the icon link (the catalog default clears the override) and returns it as a URL.
    /// Anything but an http(s) link throws `.notAWebLink` and changes nothing.
    @discardableResult
    public mutating func setLink(_ text: String, for badge: OSBadge) throws(BadgeImageError) -> URL {
        let url = try BadgeImageRules.webURL(from: text)
        let link = url.absoluteString
        update(badge) {
            $0.link = link == OSCatalog.shared.entry(for: badge)?.defaultLink ? nil : link
        }
        return url
    }

    public mutating func setImageSource(_ link: String?, for badge: OSBadge) {
        update(badge) { $0.imageSource = link }
    }

    /// Back to white, the standard color and the default link; forgets the image source.
    public mutating func reset(_ badge: OSBadge) {
        appearances[badge] = nil
    }

    private mutating func update(_ badge: OSBadge, _ change: (inout Appearance) -> Void) {
        var appearance = appearances[badge] ?? Appearance()
        change(&appearance)
        appearances[badge] = appearance.isDefault ? nil : appearance
    }

    // MARK: JSON

    private struct FileFormat: Encodable {
        var version: Int
        var badges: [String: Entry]
    }

    private struct Entry: Codable {
        var showInWhite: Bool?
        var color: String?
        var link: String?
        var source: String?

        init(showInWhite: Bool?, color: String?, link: String?, source: String?) {
            self.showInWhite = showInWhite; self.color = color; self.link = link; self.source = source
        }

        /// Every field on its own: a value of the wrong type drops only that value.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showInWhite = try? container.decodeIfPresent(Bool.self, forKey: .showInWhite)
            color = try? container.decodeIfPresent(String.self, forKey: .color)
            link = try? container.decodeIfPresent(String.self, forKey: .link)
            source = try? container.decodeIfPresent(String.self, forKey: .source)
        }
    }

    private struct LenientFile: Decodable {
        var badges: [String: Lenient<Entry>]?

        init(from decoder: Decoder) throws {
            // Must be an object; everything inside it is optional.
            let container = try decoder.container(keyedBy: CodingKeys.self)
            badges = try? container.decodeIfPresent([String: Lenient<Entry>].self, forKey: .badges)
        }

        private enum CodingKeys: String, CodingKey { case badges }
    }

    /// Reads `settings.json`. Throws only when the data isn't a JSON object.
    public init(jsonData: Data) throws {
        let file = try JSONDecoder().decode(LenientFile.self, from: jsonData)
        let entries = file.badges ?? [:]
        // Legacy keys first, so an entry under the current id overwrites its legacy twin.
        let ordered = entries.sorted { lhs, rhs in
            let l = BadgeStyle.legacyLogoFileNames[lhs.key] != nil
            let r = BadgeStyle.legacyLogoFileNames[rhs.key] != nil
            return l != r ? l : lhs.key < rhs.key
        }
        for (key, lenient) in ordered {
            guard let entry = lenient.value else { continue }
            let badge = BadgeStyle.legacyLogoFileNames[key] ?? OSBadge(rawValue: key)
            guard OSCatalog.shared.contains(badge), OSCatalog.isValidID(key) else { continue }
            appearances[badge] = nil
            if let showInWhite = entry.showInWhite {
                setShowsInWhite(showInWhite, for: badge)
            }
            if let color = entry.color {
                setColor(color, for: badge)
            }
            if let link = entry.link {
                _ = try? setLink(link, for: badge)
            }
            if let source = entry.source, let url = try? BadgeImageRules.webURL(from: source) {
                setImageSource(url.absoluteString, for: badge)
            }
        }
    }

    /// Pretty-printed with sorted keys, so the file diffs and reads well.
    public func jsonData() throws -> Data {
        var badges: [String: Entry] = [:]
        for (badge, appearance) in appearances {
            guard let key = BadgeStyle.logoFileName(for: badge) else { continue }
            badges[key] = Entry(showInWhite: appearance.showsInWhite, color: appearance.hexColor,
                                link: appearance.link, source: appearance.imageSource)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(FileFormat(version: Self.currentVersion, badges: badges))
    }
}
