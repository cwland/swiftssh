import Foundation
import CoreModels

/// The operating systems the app knows: names, categories, default icon links, badge colors and
/// fallback symbols. Built from two bundled files in `Sources/AppCore/Resources`:
///
/// - `os-catalog.json` — Cory's list, shipped verbatim: `{ "<category_key>": [ { "id", "name", "icon" } ] }`.
/// - `os-catalog-app.json` — the app's overlay: category order, titles and symbols, extra entries
///   (Home Assistant), and per-id badge colors and symbols.
///
/// Reading is lenient: entries with a missing name, an id that isn't a safe file name
/// (`isValidID`) or a repeated id are skipped; a link that isn't http(s) becomes "" (no default
/// download); a bad color or a missing symbol falls back. Only data that isn't a JSON object throws.
public struct OSCatalog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: OSBadge
        public let name: String
        /// Default icon link ("" when the catalog has no usable one).
        public let defaultLink: String
        public let categoryKey: String
        /// Default badge background, "#RRGGBB".
        public let hexColor: String
        /// SF Symbol drawn when there's no image.
        public let symbol: String
    }

    public struct Category: Equatable, Sendable, Identifiable {
        public let key: String
        public let title: String
        public let entries: [Entry]
        public var id: String { key }
    }

    public let categories: [Category]
    public let fallbackHexColor: String
    public let fallbackSymbol: String
    public let entries: [Entry]
    private let index: [OSBadge: Int]

    public func entry(for badge: OSBadge?) -> Entry? {
        badge.flatMap { index[$0] }.map { entries[$0] }
    }

    public func contains(_ badge: OSBadge) -> Bool {
        index[badge] != nil
    }

    /// Lowercase letters, digits and dashes, starting with a letter or digit, at most 64 long:
    /// ids become file names in the Badges folder.
    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.unicodeScalars.count <= 64 else { return false }
        func isLowerAlnum(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        return isLowerAlnum(first) && id.unicodeScalars.allSatisfy { isLowerAlnum($0) || $0 == "-" }
    }

    // MARK: Loading

    public static let catalogResourceName = "os-catalog"
    public static let overlayResourceName = "os-catalog-app"

    /// The bundled catalog; empty (every badge generic) only if the bundle is broken, which the
    /// tests rule out.
    public static let shared: OSCatalog = {
        do {
            return try bundled()
        } catch {
            NSLog("Could not read the bundled OS catalog: %@", String(describing: error))
            return OSCatalog(categories: [], fallbackHexColor: defaultFallbackColor, fallbackSymbol: defaultFallbackSymbol)
        }
    }()

    public static func bundled() throws -> OSCatalog {
        guard let catalogURL = resourceURL(catalogResourceName), let overlayURL = resourceURL(overlayResourceName) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try OSCatalog(catalogJSON: Data(contentsOf: catalogURL), overlayJSON: Data(contentsOf: overlayURL))
    }

    static func resourceURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json")
    }

    static let defaultFallbackColor = "#5B6475"
    static let defaultFallbackSymbol = "terminal"

    public init(catalogJSON: Data, overlayJSON: Data) throws {
        let decoder = JSONDecoder()
        let lists = try decoder.decode([String: Lenient<[Lenient<RawEntry>]>].self, from: catalogJSON)
        let overlay = try decoder.decode(Overlay.self, from: overlayJSON)

        let fallbackColor = overlay.fallback?.color.flatMap(BadgeColor.normalizedHex) ?? Self.defaultFallbackColor
        let fallbackSymbol = overlay.fallback?.symbol.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultFallbackSymbol
        let extras = overlay.extraEntries ?? [:]
        let styles = overlay.entries ?? [:]

        // Overlay order first, then any other category in the catalog files, by key.
        var keys: [String] = []
        for category in overlay.categories ?? [] where !keys.contains(category.key) {
            keys.append(category.key)
        }
        for key in Set(lists.keys).union(extras.keys).sorted() where !keys.contains(key) {
            keys.append(key)
        }

        var seen: Set<OSBadge> = []
        var categories: [Category] = []
        for key in keys {
            let info = overlay.categories?.first { $0.key == key }
            let raw = (lists[key]?.value ?? []).compactMap(\.value) + (extras[key] ?? []).compactMap(\.value)
            var entries: [Entry] = []
            for item in raw {
                guard Self.isValidID(item.id), let name = item.name?.trimmingCharacters(in: .whitespaces),
                      !name.isEmpty else { continue }
                let badge = OSBadge(rawValue: item.id)
                guard badge.rawValue == item.id, seen.insert(badge).inserted else { continue }
                let style = styles[item.id]
                let link = item.icon.flatMap { try? BadgeImageRules.webURL(from: $0) }.map(\.absoluteString) ?? ""
                entries.append(Entry(
                    id: badge, name: name, defaultLink: link, categoryKey: key,
                    hexColor: style?.color.flatMap(BadgeColor.normalizedHex) ?? fallbackColor,
                    symbol: style?.symbol.flatMap { $0.isEmpty ? nil : $0 }
                        ?? info?.symbol.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackSymbol))
            }
            guard !entries.isEmpty else { continue }
            categories.append(Category(key: key, title: info?.title ?? Self.title(fromKey: key), entries: entries))
        }
        self.init(categories: categories, fallbackHexColor: fallbackColor, fallbackSymbol: fallbackSymbol)
    }

    init(categories: [Category], fallbackHexColor: String, fallbackSymbol: String) {
        self.categories = categories
        self.fallbackHexColor = fallbackHexColor
        self.fallbackSymbol = fallbackSymbol
        entries = categories.flatMap(\.entries)
        var index: [OSBadge: Int] = [:]
        for (offset, entry) in entries.enumerated() { index[entry.id] = offset }
        self.index = index
    }

    public static func == (lhs: OSCatalog, rhs: OSCatalog) -> Bool {
        lhs.categories == rhs.categories && lhs.fallbackHexColor == rhs.fallbackHexColor
            && lhs.fallbackSymbol == rhs.fallbackSymbol
    }

    /// "zeta_things" → "Zeta Things".
    private static func title(fromKey key: String) -> String {
        key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: File formats

    private struct RawEntry: Decodable {
        var id: String
        var name: String?
        var icon: String?
    }

    private struct Overlay: Decodable {
        struct CategoryInfo: Decodable {
            var key: String
            var title: String?
            var symbol: String?
        }
        struct Style: Decodable {
            var color: String?
            var symbol: String?
        }
        var fallback: Style?
        var categories: [CategoryInfo]?
        var extraEntries: [String: [Lenient<RawEntry>]]?
        var entries: [String: Style]?
    }
}

/// Decodes `T` or, when that fails, nothing — so one bad element doesn't fail its container.
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
