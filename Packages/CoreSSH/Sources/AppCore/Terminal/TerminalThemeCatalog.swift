import Foundation

public enum TerminalThemeCatalogError: Error, Equatable, Sendable {
    /// The data isn't JSON, or its top level isn't an object.
    case notAJSONObject
    /// `version` isn't 1 (0 when it is missing or not a number).
    case unsupportedVersion(Int)
}

/// The terminal themes the app ships, read from `Sources/AppCore/Resources/terminal-themes.json`:
///
/// ```
/// { "version": 1,
///   "credits": { "<key>": { "project", "author", "license", "copyright", "url", "files" } },
///   "themes": [ { "id", "name", "appearance": "light"|"dark", "credit": "<key>"|null,
///                 "background", "foreground", "cursor", "selection", "ansi": [16 × "#RRGGBB"],
///                 "notes"? } ] }
/// ```
///
/// Strict on the bundled data (the tests fail on any skipped entry), lenient at runtime: a bad entry
/// is skipped and listed in `skippedEntries` rather than crashing. `notes` documents any change from
/// the upstream colors and isn't read by the app. Attribution text is `terminal-themes-notices.txt`.
public struct TerminalThemeCatalog: Sendable {
    public static let lightDefaultID = "reimagined-light"
    public static let darkDefaultID = "reimagined-dark"

    static let catalogResourceName = "terminal-themes"
    static let noticesResourceName = "terminal-themes-notices"

    /// Loaded from `Bundle.module` `terminal-themes.json`; a load failure is a programmer error
    /// (fatalError with the reason) because the file ships with the app and is tested.
    public static let shared: TerminalThemeCatalog = {
        guard let url = Bundle.module.url(forResource: catalogResourceName, withExtension: "json") else {
            fatalError("terminal-themes.json is missing from the AppCore bundle")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fatalError("Could not read terminal-themes.json: \(error)")
        }
        let catalog: TerminalThemeCatalog
        do {
            catalog = try TerminalThemeCatalog(jsonData: data)
        } catch {
            fatalError("terminal-themes.json is not a valid theme catalog: \(error)")
        }
        guard catalog.contains(lightDefaultID), catalog.contains(darkDefaultID) else {
            fatalError("terminal-themes.json lacks \(lightDefaultID) or \(darkDefaultID)")
        }
        return catalog
    }()

    /// The bundled notices text (`terminal-themes-notices.txt`), "" if missing. Read once.
    public static var noticesText: String { cachedNoticesText }

    private static let cachedNoticesText: String = {
        guard let url = Bundle.module.url(forResource: noticesResourceName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    /// File order = gallery order.
    public let themes: [TerminalTheme]
    /// Ids (or "#<index>" when the id is unreadable) of entries that were skipped.
    public let skippedEntries: [String]
    private let index: [String: Int]

    /// Throws for a non-object or a `version` other than 1. A theme entry with a missing field,
    /// a bad hex, an ansi count other than 16, an unknown appearance, a duplicate id or an
    /// unknown credit key is skipped (and listed in `skippedEntries`).
    public init(jsonData: Data) throws(TerminalThemeCatalogError) {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: jsonData)
        } catch {
            throw .notAJSONObject
        }
        guard file.version == 1 else { throw .unsupportedVersion(file.version ?? 0) }

        var credits: [String: ThemeCredit] = [:]
        for (key, raw) in file.credits ?? [:] {
            guard let raw = raw.value else { continue }
            credits[key] = ThemeCredit(key: key, project: raw.project, author: raw.author, license: raw.license,
                                       copyright: raw.copyright, url: raw.url, files: raw.files)
        }

        var themes: [TerminalTheme] = []
        var skipped: [String] = []
        var index: [String: Int] = [:]
        for (offset, raw) in (file.themes ?? []).enumerated() {
            guard let theme = raw.theme(credits: credits), index[theme.id] == nil else {
                skipped.append(raw.id.map { $0.isEmpty ? "#\(offset)" : $0 } ?? "#\(offset)")
                continue
            }
            index[theme.id] = themes.count
            themes.append(theme)
        }
        self.themes = themes
        self.skippedEntries = skipped
        self.index = index
    }

    public func theme(id: String) -> TerminalTheme? {
        index[id].map { themes[$0] }
    }

    public func contains(_ id: String) -> Bool {
        index[id] != nil
    }

    /// Credits used by at least one theme, in first-use order.
    public var credits: [ThemeCredit] {
        var seen: Set<String> = []
        return themes.compactMap(\.credit).filter { seen.insert($0.key).inserted }
    }

    /// Reimagined Light or Reimagined Dark. A catalog without them (only test data) falls back to
    /// its first theme of that appearance, then its first theme, then the bundled catalog's.
    public func automatic(prefersDark: Bool) -> TerminalTheme {
        let id = prefersDark ? Self.darkDefaultID : Self.lightDefaultID
        if let theme = theme(id: id) { return theme }
        let appearance: ThemeAppearance = prefersDark ? .dark : .light
        if let theme = themes.first(where: { $0.appearance == appearance }) ?? themes.first { return theme }
        return Self.shared.automatic(prefersDark: prefersDark)
    }

    // MARK: File format

    private struct File: Decodable {
        var version: Int?
        var credits: [String: Lenient<RawCredit>]?
        var themes: [RawTheme]?

        enum CodingKeys: String, CodingKey { case version, credits, themes }

        /// Throws only when the top level isn't an object; every field is read on its own.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try? container.decodeIfPresent(Int.self, forKey: .version)
            credits = try? container.decodeIfPresent([String: Lenient<RawCredit>].self, forKey: .credits)
            themes = try? container.decodeIfPresent([RawTheme].self, forKey: .themes)
        }
    }

    private struct RawCredit: Decodable {
        var project: String
        var author: String
        var license: String
        var copyright: String
        var url: String
        var files: String
    }

    /// One `themes` element; never fails to decode, so one bad entry can't hide the rest.
    private struct RawTheme: Decodable {
        enum CreditField { case missing, null, key(String) }

        var id: String?
        var name: String?
        var appearance: String?
        var credit: CreditField = .missing
        var background: String?
        var foreground: String?
        var cursor: String?
        var selection: String?
        var ansi: [String]?

        enum CodingKeys: String, CodingKey {
            case id, name, appearance, credit, background, foreground, cursor, selection, ansi
        }

        init(from decoder: Decoder) {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            appearance = try? container.decodeIfPresent(String.self, forKey: .appearance)
            if container.contains(.credit) {
                if (try? container.decodeNil(forKey: .credit)) == true {
                    credit = .null
                } else if let key = try? container.decode(String.self, forKey: .credit) {
                    credit = .key(key)
                }
            }
            background = try? container.decodeIfPresent(String.self, forKey: .background)
            foreground = try? container.decodeIfPresent(String.self, forKey: .foreground)
            cursor = try? container.decodeIfPresent(String.self, forKey: .cursor)
            selection = try? container.decodeIfPresent(String.self, forKey: .selection)
            ansi = try? container.decodeIfPresent([String].self, forKey: .ansi)
        }

        func theme(credits: [String: ThemeCredit]) -> TerminalTheme? {
            guard let id, !id.isEmpty, let name, !name.isEmpty,
                  let appearance = appearance.flatMap(ThemeAppearance.init(rawValue:)),
                  let background = background.flatMap(RGBColor.init(hex:)),
                  let foreground = foreground.flatMap(RGBColor.init(hex:)),
                  let cursor = cursor.flatMap(RGBColor.init(hex:)),
                  let selection = selection.flatMap(RGBColor.init(hex:)),
                  let ansiStrings = ansi, ansiStrings.count == 16 else { return nil }
            let palette = ansiStrings.compactMap(RGBColor.init(hex:))
            guard palette.count == 16 else { return nil }
            let themeCredit: ThemeCredit?
            switch credit {
            case .missing: return nil
            case .null: themeCredit = nil
            case .key(let key):
                guard let found = credits[key] else { return nil }
                themeCredit = found
            }
            return TerminalTheme(id: id, name: name, appearance: appearance, background: background,
                                 foreground: foreground, cursor: cursor, selection: selection,
                                 ansi: palette, credit: themeCredit)
        }
    }
}
