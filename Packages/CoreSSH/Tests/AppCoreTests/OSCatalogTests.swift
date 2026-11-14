import XCTest
import CoreModels
@testable import AppCore

final class OSCatalogTests: XCTestCase {
    private let catalog = OSCatalog.shared

    func testBundledCatalogLoadsAllCategoriesInOrder() throws {
        let bundled = try OSCatalog.bundled()
        XCTAssertEqual(bundled, catalog)
        XCTAssertEqual(catalog.categories.map(\.title), [
            "Desktop & Server", "Linux Distributions", "NAS", "Routers & Firewalls",
            "Hypervisors & Containers", "BSD & Unix", "Home Automation",
        ])
        XCTAssertEqual(catalog.categories.map(\.key), [
            "desktop_and_server", "linux_distributions", "nas_operating_systems", "routers_and_firewalls",
            "hypervisors_and_containers", "bsd_and_unix", "home_automation",
        ])
        XCTAssertEqual(catalog.categories.map(\.entries.count), [5, 19, 9, 9, 4, 3, 1])
        XCTAssertEqual(catalog.entries.count, 50)
        XCTAssertEqual(Set(catalog.entries.map(\.id)).count, 50, "ids are unique")
    }

    func testEntriesKeepCorysOrderNamesAndLinks() throws {
        let linux = try XCTUnwrap(catalog.categories.first { $0.key == "linux_distributions" })
        XCTAssertEqual(linux.entries.prefix(3).map(\.id.rawValue), ["ubuntu", "debian", "rhel"])
        XCTAssertEqual(linux.entries.last?.id.rawValue, "amzn")
        let rhel = try XCTUnwrap(catalog.entry(for: .rhel))
        XCTAssertEqual(rhel.name, "Red Hat Enterprise Linux (RHEL)")
        XCTAssertEqual(rhel.defaultLink, "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/redhat.svg")
        XCTAssertEqual(rhel.categoryKey, "linux_distributions")
        XCTAssertEqual(catalog.entry(for: OSBadge(rawValue: "xcpng"))?.name, "XCP-ng")
        XCTAssertEqual(catalog.entry(for: .windows)?.name, "Windows (11 / Server)")
        XCTAssertEqual(catalog.entry(for: .windows10)?.defaultLink,
                       "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/windows-10.svg")
        XCTAssertEqual(catalog.entry(for: .freebsd)?.defaultLink, "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/freebsd.svg")
        XCTAssertEqual(catalog.entry(for: .fortinet)?.defaultLink,
                       "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/fortigate.svg")
    }

    func testHomeAssistantComesFromTheOverlay() throws {
        let ha = try XCTUnwrap(catalog.entry(for: .homeAssistant))
        XCTAssertEqual(ha.name, "Home Assistant")
        XCTAssertEqual(ha.categoryKey, "home_automation")
        XCTAssertEqual(ha.defaultLink, "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/home-assistant.svg")
    }

    func testEveryEntryHasAValidIDLinkColorAndSymbol() {
        for entry in catalog.entries {
            XCTAssertTrue(OSCatalog.isValidID(entry.id.rawValue), entry.id.rawValue)
            XCTAssertNotNil(try? BadgeImageRules.webURL(from: entry.defaultLink), entry.id.rawValue)
            XCTAssertTrue(entry.defaultLink.hasPrefix("https://cdn.jsdelivr.net/gh/"), entry.defaultLink)
            XCTAssertEqual(BadgeColor.normalizedHex(entry.hexColor), entry.hexColor, entry.id.rawValue)
            XCTAssertFalse(entry.symbol.isEmpty, entry.id.rawValue)
            XCTAssertFalse(entry.name.isEmpty, entry.id.rawValue)
        }
    }

    func testGenericEntriesAreGrey() {
        XCTAssertEqual(catalog.fallbackHexColor, "#5B6475")
        XCTAssertEqual(catalog.entry(for: .linux)?.hexColor, "#5B6475")
    }

    func testRemovedIDsAreNotInTheCatalogButStillDecodeAsGenericBadges() throws {
        for removed in ["windows-legacy", "elementary", "router-generic"] {
            let badge = try JSONDecoder().decode([OSBadge].self, from: Data("[\"\(removed)\"]".utf8))[0]
            XCTAssertEqual(badge.rawValue, removed)
            XCTAssertFalse(catalog.contains(badge), removed)
            XCTAssertEqual(BadgeStyle.hexColor(for: badge), "#5B6475")
            XCTAssertEqual(BadgeStyle.symbol(for: badge), "terminal")
        }
    }

    func testLookupOfUnknownOrNil() {
        XCTAssertNil(catalog.entry(for: nil))
        XCTAssertNil(catalog.entry(for: OSBadge(rawValue: "plan9")))
        XCTAssertTrue(catalog.contains(.ubuntu))
        XCTAssertFalse(catalog.contains(OSBadge(rawValue: "plan9")))
    }

    func testLegacyBadgesAreAllInTheCatalog() {
        for raw in ["ubuntu", "debian", "raspberryPiOS", "fedora", "rhel", "alpine", "arch", "macOS", "freeBSD",
                    "linux", "synology", "homeAssistant"] {
            XCTAssertTrue(catalog.contains(OSBadge(rawValue: raw)), raw)
        }
    }

    func testNamedConstantsAreCatalogIDs() {
        for badge in OSBadge.namedCatalogConstants {
            XCTAssertTrue(catalog.contains(badge), badge.rawValue)
        }
        XCTAssertEqual(OSBadge.namedCatalogConstants.count, 50)
    }

    func testIDValidation() {
        for good in ["ubuntu", "home-assistant", "xcpng", "router-generic", "a1"] {
            XCTAssertTrue(OSCatalog.isValidID(good), good)
        }
        for bad in ["", "Ubuntu", "../etc", "a/b", "a b", "-x", "a.svg", String(repeating: "a", count: 65)] {
            XCTAssertFalse(OSCatalog.isValidID(bad), bad)
        }
    }

    func testParsingIsLenientAndOrderedByOverlay() throws {
        let catalogJSON = """
        {
          "zeta_things": [{"id": "zed", "name": "Zed", "icon": "https://example.com/z.svg"}],
          "linux_distributions": [
            {"id": "ubuntu", "name": "Ubuntu", "icon": "https://example.com/u.svg"},
            {"id": "ubuntu", "name": "Duplicate", "icon": "https://example.com/d.svg"},
            {"id": "../evil", "name": "Bad id", "icon": "https://example.com/e.svg"},
            {"id": "noname", "icon": "https://example.com/n.svg"},
            {"id": "badlink", "name": "Bad link", "icon": "ftp://example.com/b.svg"},
            42
          ],
          "desktop_and_server": [{"id": "macos", "name": "macOS", "icon": "https://example.com/m.svg"}]
        }
        """
        let overlayJSON = """
        {
          "fallback": {"color": "#5b6475", "symbol": "terminal"},
          "categories": [
            {"key": "desktop_and_server", "title": "Desktop & Server", "symbol": "desktopcomputer"},
            {"key": "linux_distributions", "title": "Linux Distributions"},
            {"key": "empty_one", "title": "Empty"}
          ],
          "extraEntries": {"linux_distributions": [
            {"id": "extra", "name": "Extra", "icon": "https://example.com/x.svg"},
            {"id": "ubuntu", "name": "Not me", "icon": "https://example.com/n.svg"}
          ]},
          "entries": {"ubuntu": {"color": "#e2602f", "symbol": "cpu"}, "macos": {"color": "nope"}}
        }
        """
        let parsed = try OSCatalog(catalogJSON: Data(catalogJSON.utf8), overlayJSON: Data(overlayJSON.utf8))
        XCTAssertEqual(parsed.categories.map(\.key), ["desktop_and_server", "linux_distributions", "zeta_things"])
        XCTAssertEqual(parsed.categories.map(\.title), ["Desktop & Server", "Linux Distributions", "Zeta Things"])
        let linux = parsed.categories[1]
        XCTAssertEqual(linux.entries.map(\.id.rawValue), ["ubuntu", "badlink", "extra"])
        XCTAssertEqual(linux.entries[0].name, "Ubuntu")
        XCTAssertEqual(linux.entries[0].hexColor, "#E2602F")
        XCTAssertEqual(linux.entries[0].symbol, "cpu")
        XCTAssertEqual(linux.entries[1].defaultLink, "", "a link that isn't http(s) is dropped")
        XCTAssertEqual(linux.entries[2].symbol, "terminal", "category without symbol uses the fallback")
        XCTAssertEqual(parsed.entry(for: .macos)?.hexColor, "#5B6475", "bad color uses the fallback")
        XCTAssertEqual(parsed.entry(for: .macos)?.symbol, "desktopcomputer")
        XCTAssertThrowsError(try OSCatalog(catalogJSON: Data("[]".utf8), overlayJSON: Data(overlayJSON.utf8)))
    }

    func testBundledCatalogFileIsCorysVerbatim() throws {
        let url = try XCTUnwrap(OSCatalog.resourceURL(OSCatalog.catalogResourceName))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [[String: String]]])
        XCTAssertEqual(object.values.map(\.count).reduce(0, +), 49)
        XCTAssertNil(object["home_automation"], "Home Assistant lives in the overlay, not in Cory's file")
    }
}
