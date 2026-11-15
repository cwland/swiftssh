import XCTest
import CoreModels
@testable import AppCore

final class BadgeSettingsTests: XCTestCase {
    private let ubuntuDefault = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/ubuntu.svg"

    func testDefaultsAreWhiteWithStyleColorAndCatalogLink() {
        let settings = BadgeSettings()
        for entry in OSCatalog.shared.entries {
            let badge = entry.id
            XCTAssertTrue(settings.showsInWhite(for: badge), "\(badge)")
            XCTAssertEqual(settings.hexColor(for: badge), BadgeStyle.hexColor(for: badge), "\(badge)")
            XCTAssertEqual(settings.link(for: badge), entry.defaultLink, "\(badge)")
            XCTAssertNil(settings.imageSource(for: badge), "\(badge)")
            XCTAssertFalse(settings.hasCustomSettings(for: badge), "\(badge)")
        }
        XCTAssertEqual(settings.hexColor(for: nil), BadgeStyle.hexColor(for: nil))
        XCTAssertTrue(settings.showsInWhite(for: nil))
        XCTAssertEqual(settings.link(for: OSBadge(rawValue: "plan9")), "")
    }

    func testColorOverrideIsNormalizedAndDefaultColorClearsIt() {
        var settings = BadgeSettings()
        settings.setColor("  #aabbcc ", for: .ubuntu)
        XCTAssertEqual(settings.hexColor(for: .ubuntu), "#AABBCC")
        XCTAssertTrue(settings.hasCustomSettings(for: .ubuntu))
        XCTAssertEqual(settings.hexColor(for: .debian), BadgeStyle.hexColor(for: .debian))

        settings.setColor(BadgeStyle.hexColor(for: .ubuntu).lowercased(), for: .ubuntu)
        XCTAssertEqual(settings.hexColor(for: .ubuntu), BadgeStyle.hexColor(for: .ubuntu))
        XCTAssertFalse(settings.hasCustomSettings(for: .ubuntu))
        XCTAssertEqual(settings, BadgeSettings())
    }

    func testInvalidColorIsIgnored() {
        var settings = BadgeSettings()
        settings.setColor("#12345", for: .arch)
        settings.setColor("blue", for: .arch)
        XCTAssertEqual(settings.hexColor(for: .arch), BadgeStyle.hexColor(for: .arch))
        XCTAssertEqual(settings, BadgeSettings())
    }

    func testShowInWhiteToggleAndReset() {
        var settings = BadgeSettings()
        settings.setShowsInWhite(false, for: .synology)
        settings.setColor("#010203", for: .synology)
        XCTAssertFalse(settings.showsInWhite(for: .synology))
        XCTAssertTrue(settings.hasCustomSettings(for: .synology))
        settings.setShowsInWhite(true, for: .synology)
        XCTAssertTrue(settings.showsInWhite(for: .synology))
        settings.reset(.synology)
        XCTAssertEqual(settings, BadgeSettings())
    }

    func testLinkOverrideIsValidatedAndTheDefaultClearsIt() throws {
        var settings = BadgeSettings()
        let url = try settings.setLink("  https://example.com/u.png ", for: .ubuntu)
        XCTAssertEqual(url.absoluteString, "https://example.com/u.png")
        XCTAssertEqual(settings.link(for: .ubuntu), "https://example.com/u.png")
        XCTAssertTrue(settings.hasCustomLink(for: .ubuntu))
        XCTAssertTrue(settings.hasCustomSettings(for: .ubuntu))

        XCTAssertThrowsError(try settings.setLink("ftp://example.com/x.png", for: .ubuntu)) { error in
            XCTAssertEqual(error as? BadgeImageError, .notAWebLink)
        }
        XCTAssertThrowsError(try settings.setLink("   ", for: .ubuntu))
        XCTAssertEqual(settings.link(for: .ubuntu), "https://example.com/u.png", "a bad link changes nothing")

        _ = try settings.setLink(ubuntuDefault, for: .ubuntu)
        XCTAssertEqual(settings.link(for: .ubuntu), ubuntuDefault)
        XCTAssertFalse(settings.hasCustomLink(for: .ubuntu))
        XCTAssertEqual(settings, BadgeSettings())
    }

    func testImageSourceIsANonDefaultValueAndResetClearsEverything() throws {
        var settings = BadgeSettings()
        settings.setImageSource(ubuntuDefault, for: .ubuntu)
        XCTAssertEqual(settings.imageSource(for: .ubuntu), ubuntuDefault)
        XCTAssertTrue(settings.hasCustomSettings(for: .ubuntu), "a remembered source counts as non-default")
        settings.setImageSource(nil, for: .ubuntu)
        XCTAssertEqual(settings, BadgeSettings())

        _ = try settings.setLink("https://example.com/a.svg", for: .debian)
        settings.setImageSource("https://example.com/a.svg", for: .debian)
        settings.setColor("#000000", for: .debian)
        settings.setShowsInWhite(false, for: .debian)
        settings.reset(.debian)
        XCTAssertEqual(settings, BadgeSettings())
    }

    func testJSONRoundTripUsesCatalogIDsAsKeys() throws {
        var settings = BadgeSettings()
        settings.setShowsInWhite(false, for: .homeAssistant)
        settings.setColor("#112233", for: .raspbian)
        _ = try settings.setLink("https://example.com/p.png", for: .proxmox)
        settings.setImageSource("https://example.com/p.png", for: .proxmox)
        let data = try settings.jsonData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"home-assistant\""), text)
        XCTAssertTrue(text.contains("\"raspbian\""), text)
        XCTAssertTrue(text.contains("\"link\" : \"https://example.com/p.png\""), text)
        XCTAssertTrue(text.contains("\"source\""), text)
        XCTAssertTrue(text.contains("\"version\" : 2"), text)
        XCTAssertFalse(text.contains("\"ubuntu\""), "untouched badges are not written: \(text)")
        let decoded = try BadgeSettings(jsonData: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.showsInWhite(for: .homeAssistant))
        XCTAssertEqual(decoded.hexColor(for: .raspbian), "#112233")
        XCTAssertEqual(decoded.link(for: .proxmox), "https://example.com/p.png")
        XCTAssertEqual(decoded.imageSource(for: .proxmox), "https://example.com/p.png")
    }

    func testVersion1FileWithLegacyKeysMigrates() throws {
        let json = """
        {"version": 1, "badges": {
            "raspberry-pi": {"showInWhite": false, "color": "#ABCDEF"},
            "home-assistant": {"color": "#010101"}
        }}
        """
        let settings = try BadgeSettings(jsonData: Data(json.utf8))
        XCTAssertFalse(settings.showsInWhite(for: .raspbian))
        XCTAssertEqual(settings.hexColor(for: .raspbian), "#ABCDEF")
        XCTAssertEqual(settings.hexColor(for: .homeAssistant), "#010101")
        let rewritten = try XCTUnwrap(String(data: settings.jsonData(), encoding: .utf8))
        XCTAssertTrue(rewritten.contains("\"raspbian\""))
        XCTAssertFalse(rewritten.contains("raspberry-pi"))
    }

    func testNewKeyWinsOverItsLegacyKey() throws {
        let json = """
        {"badges": {"raspbian": {"color": "#111111"}, "raspberry-pi": {"color": "#222222", "showInWhite": false}}}
        """
        let settings = try BadgeSettings(jsonData: Data(json.utf8))
        XCTAssertEqual(settings.hexColor(for: .raspbian), "#111111")
        XCTAssertTrue(settings.showsInWhite(for: .raspbian))
    }

    func testDecodingIsLenientPerField() throws {
        let json = """
        {"version": "two", "badges": {
            "ubuntu": {"color": "#00ff00", "showInWhite": "yes"},
            "debian": {"showInWhite": false, "color": 7},
            "fedora": {"link": "javascript:alert(1)", "source": 12, "color": "#123456"},
            "arch": {"link": "https://example.com/a.png", "source": "https://example.com/a.png"},
            "alpine": "not an object",
            "plan9": {"showInWhite": false},
            "../evil": {"color": "#FFFFFF"},
            "rhel": {}
        }, "future": true}
        """
        let settings = try BadgeSettings(jsonData: Data(json.utf8))
        XCTAssertEqual(settings.hexColor(for: .ubuntu), "#00FF00")
        XCTAssertTrue(settings.showsInWhite(for: .ubuntu))
        XCTAssertFalse(settings.showsInWhite(for: .debian))
        XCTAssertEqual(settings.hexColor(for: .debian), BadgeStyle.hexColor(for: .debian))
        XCTAssertEqual(settings.hexColor(for: .fedora), "#123456")
        XCTAssertFalse(settings.hasCustomLink(for: .fedora))
        XCTAssertNil(settings.imageSource(for: .fedora))
        XCTAssertEqual(settings.link(for: .arch), "https://example.com/a.png")
        XCTAssertEqual(settings.imageSource(for: .arch), "https://example.com/a.png")
        XCTAssertFalse(settings.hasCustomSettings(for: .alpine))
        XCTAssertFalse(settings.hasCustomSettings(for: .rhel))
    }

    func testBadgesThatAreNotAnObjectStillDecode() throws {
        XCTAssertEqual(try BadgeSettings(jsonData: Data("{\"badges\": [1, 2]}".utf8)), BadgeSettings())
    }

    func testEmptyObjectDecodesToDefaultsAndGarbageThrows() throws {
        XCTAssertEqual(try BadgeSettings(jsonData: Data("{}".utf8)), BadgeSettings())
        XCTAssertThrowsError(try BadgeSettings(jsonData: Data("nope".utf8)))
    }
}

final class BadgeColorTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(BadgeColor.normalizedHex("#e2602f"), "#E2602F")
        XCTAssertEqual(BadgeColor.normalizedHex("E2602F"), "#E2602F")
        XCTAssertEqual(BadgeColor.normalizedHex(" #abc "), "#AABBCC")
        XCTAssertNil(BadgeColor.normalizedHex(""))
        XCTAssertNil(BadgeColor.normalizedHex("#"))
        XCTAssertNil(BadgeColor.normalizedHex("#GG0000"))
        XCTAssertNil(BadgeColor.normalizedHex("#1234567"))
        XCTAssertNil(BadgeColor.normalizedHex("#+12345"))
        XCTAssertNil(BadgeColor.normalizedHex("##123456"))

        let rgb = BadgeColor.components(hex: "#FF8000")
        XCTAssertEqual(rgb?.red, 1)
        XCTAssertEqual(rgb?.green ?? 0, 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(rgb?.blue, 0)
        XCTAssertNil(BadgeColor.components(hex: "zzz"))
    }

    func testFormatRoundsAndClamps() {
        XCTAssertEqual(BadgeColor.hex(red: 1, green: 0.5, blue: 0), "#FF8000")
        XCTAssertEqual(BadgeColor.hex(red: -0.2, green: 1.4, blue: 0.0019), "#00FF00")
        XCTAssertEqual(BadgeColor.hex(red: .nan, green: 0, blue: 0), "#000000")
        for hex in ["#E2602F", "#000000", "#FFFFFF", "#1F4A7A"] {
            let rgb = BadgeColor.components(hex: hex)!
            XCTAssertEqual(BadgeColor.hex(red: rgb.red, green: rgb.green, blue: rgb.blue), hex)
        }
    }
}
