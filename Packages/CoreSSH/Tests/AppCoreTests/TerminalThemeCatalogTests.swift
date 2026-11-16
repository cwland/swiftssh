import XCTest
@testable import AppCore

final class TerminalThemeCatalogTests: XCTestCase {
    // MARK: Helpers

    private static let sixteen = Array(repeating: "\"#101010\"", count: 16).joined(separator: ", ")

    private func themeJSON(id: String, name: String? = nil, appearance: String = "dark", credit: String? = nil,
                           background: String = "#000000", ansi: String = sixteen) -> String {
        """
        {"id": "\(id)", "name": "\(name ?? id)", "appearance": "\(appearance)", \
        "credit": \(credit.map { "\"\($0)\"" } ?? "null"), \
        "background": "\(background)", "foreground": "#FFFFFF", "cursor": "#FFFFFF", "selection": "#333333", \
        "ansi": [\(ansi)]}
        """
    }

    private func catalogJSON(_ themes: [String], version: Int = 1, credits: String = "{}") -> Data {
        Data("""
        {"version": \(version), "credits": \(credits), "themes": [\(themes.joined(separator: ", "))]}
        """.utf8)
    }

    private static let creditJSON = """
    {"acme": {"project": "Acme", "author": "A. Person", "license": "MIT", "copyright": "Copyright (c) 2020 A. Person", \
    "url": "https://example.com/acme", "files": "acme.toml"}}
    """

    private var shared: TerminalThemeCatalog { .shared }

    // MARK: Errors

    func testInitRejectsNonObject() {
        for data in [Data("[]".utf8), Data("42".utf8), Data("not json".utf8), Data()] {
            XCTAssertThrowsError(try TerminalThemeCatalog(jsonData: data)) { error in
                XCTAssertEqual(error as? TerminalThemeCatalogError, .notAJSONObject)
            }
        }
    }

    func testInitRejectsUnknownVersion() {
        XCTAssertThrowsError(try TerminalThemeCatalog(jsonData: catalogJSON([], version: 2))) { error in
            XCTAssertEqual(error as? TerminalThemeCatalogError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try TerminalThemeCatalog(jsonData: Data(#"{"themes": []}"#.utf8))) { error in
            XCTAssertEqual(error as? TerminalThemeCatalogError, .unsupportedVersion(0))
        }
        XCTAssertNoThrow(try TerminalThemeCatalog(jsonData: catalogJSON([], version: 1)))
    }

    // MARK: Skipped entries

    func testSkipsEntryWithBadHex() throws {
        let catalog = try TerminalThemeCatalog(jsonData: catalogJSON([
            themeJSON(id: "good"),
            themeJSON(id: "bad-bg", background: "#12345"),
            themeJSON(id: "bad-ansi", ansi: Self.sixteen.replacingOccurrences(of: "\"#101010\"", with: "\"#XYZXYZ\"")),
        ]))
        XCTAssertEqual(catalog.themes.map(\.id), ["good"])
        XCTAssertEqual(catalog.skippedEntries, ["bad-bg", "bad-ansi"])
    }

    func testSkipsEntryWithFifteenANSIColors() throws {
        let fifteen = Array(repeating: "\"#101010\"", count: 15).joined(separator: ", ")
        let seventeen = Array(repeating: "\"#101010\"", count: 17).joined(separator: ", ")
        let catalog = try TerminalThemeCatalog(jsonData: catalogJSON([
            themeJSON(id: "fifteen", ansi: fifteen),
            themeJSON(id: "sixteen"),
            themeJSON(id: "seventeen", ansi: seventeen),
        ]))
        XCTAssertEqual(catalog.themes.map(\.id), ["sixteen"])
        XCTAssertEqual(catalog.skippedEntries, ["fifteen", "seventeen"])
        XCTAssertEqual(catalog.themes.first?.ansi.count, 16)
    }

    func testSkipsDuplicateID() throws {
        let catalog = try TerminalThemeCatalog(jsonData: catalogJSON([
            themeJSON(id: "twin", name: "First"),
            themeJSON(id: "twin", name: "Second"),
        ]))
        XCTAssertEqual(catalog.themes.map(\.name), ["First"])
        XCTAssertEqual(catalog.skippedEntries, ["twin"])
    }

    func testSkipsUnknownCreditKey() throws {
        let catalog = try TerminalThemeCatalog(jsonData: catalogJSON([
            themeJSON(id: "credited", credit: "acme"),
            themeJSON(id: "orphan", credit: "nobody"),
        ], credits: Self.creditJSON))
        XCTAssertEqual(catalog.themes.map(\.id), ["credited"])
        XCTAssertEqual(catalog.skippedEntries, ["orphan"])
        XCTAssertEqual(catalog.theme(id: "credited")?.credit, ThemeCredit(
            key: "acme", project: "Acme", author: "A. Person", license: "MIT",
            copyright: "Copyright (c) 2020 A. Person", url: "https://example.com/acme", files: "acme.toml"))
        XCTAssertEqual(catalog.credits.map(\.key), ["acme"])
    }

    func testSkipsUnknownAppearance() throws {
        let catalog = try TerminalThemeCatalog(jsonData: catalogJSON([
            themeJSON(id: "dusk", appearance: "dusk"),
            themeJSON(id: "light", appearance: "light"),
        ]))
        XCTAssertEqual(catalog.themes.map(\.id), ["light"])
        XCTAssertEqual(catalog.themes.first?.appearance, .light)
        XCTAssertEqual(catalog.skippedEntries, ["dusk"])
    }

    func testSkipsEntryWithMissingFieldOrUnreadableID() throws {
        let catalog = try TerminalThemeCatalog(jsonData: catalogJSON([
            #"{"id": "no-colors", "name": "No Colors", "appearance": "dark", "credit": null}"#,
            #"{"name": "No ID"}"#,
            #""just a string""#,
            themeJSON(id: "ok"),
        ]))
        XCTAssertEqual(catalog.themes.map(\.id), ["ok"])
        XCTAssertEqual(catalog.skippedEntries, ["no-colors", "#1", "#2"])
    }

    func testKeepsFileOrder() throws {
        let catalog = try TerminalThemeCatalog(jsonData: catalogJSON(["zeta", "alpha", "mid"].map { themeJSON(id: $0) }))
        XCTAssertEqual(catalog.themes.map(\.id), ["zeta", "alpha", "mid"])
        XCTAssertTrue(catalog.contains("alpha"))
        XCTAssertFalse(catalog.contains("omega"))
        XCTAssertNil(catalog.theme(id: "omega"))
        XCTAssertEqual(catalog.theme(id: "mid")?.name, "mid")
    }

    // MARK: Bundled catalog

    func testSharedCatalogHasTwentyThemesInGalleryOrder() {
        XCTAssertEqual(shared.themes.map(\.id), [
            "reimagined-light", "reimagined-dark", "flexoki-dark", "flexoki-light",
            "kanagawa-wave", "kanagawa-dragon", "kanagawa-lotus", "everforest-dark", "everforest-light",
            "night-owl", "light-owl", "rose-pine", "aura", "dracula", "solarized-dark", "solarized-light",
            "nord", "hacker-blue", "hacker-green", "hacker-red",
        ])
        XCTAssertTrue(shared.skippedEntries.isEmpty, "\(shared.skippedEntries)")
        XCTAssertEqual(shared.theme(id: "rose-pine")?.name, "Rosé Pine")
    }

    func testSharedCatalogAppearanceMatchesBackgroundLuminance() {
        for theme in shared.themes {
            switch theme.appearance {
            case .dark: XCTAssertLessThan(theme.background.relativeLuminance, 0.05, theme.id)
            case .light: XCTAssertGreaterThan(theme.background.relativeLuminance, 0.8, theme.id)
            }
        }
    }

    func testSharedCatalogForegroundContrastAtLeastFour() {
        for theme in shared.themes {
            XCTAssertGreaterThanOrEqual(theme.foreground.contrastRatio(with: theme.background), 4.0, theme.id)
        }
    }

    func testEveryThirdPartyThemeHasACreditAndOriginalsHaveNone() {
        for theme in shared.themes {
            let original = theme.id.hasPrefix("reimagined-") || theme.id.hasPrefix("hacker-")
            if original {
                XCTAssertNil(theme.credit, theme.id)
            } else {
                XCTAssertNotNil(theme.credit, theme.id)
            }
        }
        XCTAssertEqual(shared.credits.map(\.key), [
            "flexoki", "kanagawa", "everforest", "night-owl", "rose-pine", "aura", "dracula", "solarized", "nord",
        ])
    }

    func testEveryCreditIsMITAndAppearsInNotices() {
        let notices = TerminalThemeCatalog.noticesText
        XCTAssertTrue(notices.hasPrefix("Third-party terminal color themes bundled with SwiftSSH\n"))
        XCTAssertFalse(shared.credits.isEmpty)
        for credit in shared.credits {
            XCTAssertEqual(credit.license, "MIT", credit.key)
            XCTAssertTrue(notices.contains(credit.copyright), credit.key)
            XCTAssertTrue(notices.contains(credit.url), credit.key)
            XCTAssertTrue(notices.contains("\(credit.project) — \(credit.url)\nColors taken from: \(credit.files)\n"),
                          credit.key)
        }
        XCTAssertEqual(notices.components(separatedBy: "Permission is hereby granted").count - 1, shared.credits.count)
    }

    func testAutomaticPicksSwiftSSHLightOrDark() {
        XCTAssertEqual(shared.automatic(prefersDark: false).id, TerminalThemeCatalog.lightDefaultID)
        XCTAssertEqual(shared.automatic(prefersDark: true).id, TerminalThemeCatalog.darkDefaultID)
        // The ids keep the former name: they are stored in settings and synced host records.
        XCTAssertEqual(TerminalThemeCatalog.lightDefaultID, "reimagined-light")
        XCTAssertEqual(TerminalThemeCatalog.darkDefaultID, "reimagined-dark")
        XCTAssertEqual(shared.automatic(prefersDark: false).name, "SwiftSSH Light")
        XCTAssertEqual(shared.automatic(prefersDark: true).name, "SwiftSSH Dark")
    }

    func testAutomaticInACatalogWithoutTheDefaultsPicksByAppearance() throws {
        let catalog = try TerminalThemeCatalog(jsonData: catalogJSON([
            themeJSON(id: "only-dark", appearance: "dark"),
            themeJSON(id: "only-light", appearance: "light"),
        ]))
        XCTAssertEqual(catalog.automatic(prefersDark: true).id, "only-dark")
        XCTAssertEqual(catalog.automatic(prefersDark: false).id, "only-light")
        let empty = try TerminalThemeCatalog(jsonData: catalogJSON([]))
        XCTAssertEqual(empty.automatic(prefersDark: true).id, TerminalThemeCatalog.darkDefaultID)
    }

    func testSpotCheckUpstreamValues() {
        func theme(_ id: String) -> TerminalTheme { shared.theme(id: id)! }
        XCTAssertEqual(theme("dracula").background.hex, "#282A36")
        XCTAssertEqual(theme("dracula").ansi[5].hex, "#FF79C6")
        XCTAssertEqual(theme("nord").ansi[14].hex, "#8FBCBB")
        // Addendum fix: upstream #002B36 equals the background; base01 instead.
        XCTAssertEqual(theme("solarized-dark").ansi[8].hex, "#586E75")
        XCTAssertEqual(theme("solarized-dark").foreground.hex, "#839496")
        XCTAssertEqual(theme("night-owl").ansi[3].hex, "#C5E478")
        XCTAssertEqual(theme("flexoki-light").background.hex, "#FFFCF0")
        XCTAssertEqual(theme("kanagawa-wave").cursor.hex, "#C8C093")
        XCTAssertEqual(theme("everforest-dark").ansi[0].hex, "#475258")
    }

    /// Addendum rule: no ANSI color 1…15 may equal its theme's background (text in it would be
    /// invisible). ansi[0] may equal the background in dark themes ("black is the background").
    func testNoANSIColorEqualsBackground() {
        for theme in shared.themes {
            for (index, color) in theme.ansi.enumerated() where index > 0 || theme.appearance == .light {
                XCTAssertNotEqual(color, theme.background, "\(theme.id) ansi[\(index)]")
            }
        }
    }

    /// Upstream Solarized maps bright black (dark) and bright white (light) to the background; the
    /// catalog uses Solarized's own base01 / base1 and notes it in the JSON.
    func testSolarizedInvisibleSlotsUseSolarizedPalette() {
        let dark = shared.theme(id: "solarized-dark")!
        let light = shared.theme(id: "solarized-light")!
        XCTAssertEqual(dark.ansi[8].hex, "#586E75")
        XCTAssertEqual(light.ansi[15].hex, "#93A1A1")
        XCTAssertEqual(light.ansi[8].hex, "#002B36")
        XCTAssertEqual(dark.ansi[15].hex, "#FDF6E3")
    }

    func testNoticesTextIsStableAcrossReads() {
        XCTAssertFalse(TerminalThemeCatalog.noticesText.isEmpty)
        XCTAssertEqual(TerminalThemeCatalog.noticesText, TerminalThemeCatalog.noticesText)
    }

    /// Upstream Flexoki Light sets "white" (color7) to the background (#FFFCF0), so white text was
    /// invisible. The catalog uses Flexoki's base-500 (#878580, Flexoki Dark's color7) and notes it
    /// in the JSON. Every other color stays upstream.
    func testFlexokiLightWhiteIsVisible() {
        let flexoki = shared.theme(id: "flexoki-light")!
        XCTAssertEqual(flexoki.ansi[7].hex, "#878580")
        XCTAssertGreaterThanOrEqual(flexoki.ansi[7].contrastRatio(with: flexoki.background), 3.0)
        XCTAssertEqual(flexoki.ansi[15].hex, "#F2F0E5")
    }
}
