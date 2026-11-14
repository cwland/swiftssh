import XCTest
import CoreModels
@testable import AppCore

final class BadgeSettingsTests: XCTestCase {
    func testDefaultsAreWhiteWithStyleColor() {
        let settings = BadgeSettings()
        for badge in OSBadge.allCases {
            XCTAssertTrue(settings.showsInWhite(for: badge), "\(badge)")
            XCTAssertEqual(settings.hexColor(for: badge), BadgeStyle.hexColor(for: badge), "\(badge)")
            XCTAssertFalse(settings.hasCustomAppearance(for: badge), "\(badge)")
        }
        XCTAssertEqual(settings.hexColor(for: nil), BadgeStyle.hexColor(for: nil))
        XCTAssertTrue(settings.showsInWhite(for: nil))
    }

    func testColorOverrideIsNormalizedAndDefaultColorClearsIt() {
        var settings = BadgeSettings()
        settings.setColor("  #aabbcc ", for: .ubuntu)
        XCTAssertEqual(settings.hexColor(for: .ubuntu), "#AABBCC")
        XCTAssertTrue(settings.hasCustomAppearance(for: .ubuntu))
        XCTAssertEqual(settings.hexColor(for: .debian), BadgeStyle.hexColor(for: .debian))

        settings.setColor(BadgeStyle.hexColor(for: .ubuntu).lowercased(), for: .ubuntu)
        XCTAssertEqual(settings.hexColor(for: .ubuntu), BadgeStyle.hexColor(for: .ubuntu))
        XCTAssertFalse(settings.hasCustomAppearance(for: .ubuntu))
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
        XCTAssertTrue(settings.hasCustomAppearance(for: .synology))
        settings.setShowsInWhite(true, for: .synology)
        XCTAssertTrue(settings.showsInWhite(for: .synology))
        settings.reset(.synology)
        XCTAssertEqual(settings, BadgeSettings())
    }

    func testJSONRoundTripUsesFileNamesAsKeys() throws {
        var settings = BadgeSettings()
        settings.setShowsInWhite(false, for: .homeAssistant)
        settings.setColor("#112233", for: .raspberryPiOS)
        let data = try settings.jsonData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"home-assistant\""), text)
        XCTAssertTrue(text.contains("\"raspberry-pi\""), text)
        XCTAssertTrue(text.contains("\"version\" : 1"), text)
        XCTAssertFalse(text.contains("\"ubuntu\""), "untouched badges are not written: \(text)")
        let decoded = try BadgeSettings(jsonData: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.showsInWhite(for: .homeAssistant))
        XCTAssertEqual(decoded.hexColor(for: .raspberryPiOS), "#112233")
    }

    func testDecodingIsTolerant() throws {
        let json = """
        {"version": 1, "badges": {
            "ubuntu": {"color": "#00ff00"},
            "debian": {"showInWhite": false, "color": "not a color"},
            "plan9": {"showInWhite": false},
            "arch": {}
        }, "future": true}
        """
        let settings = try BadgeSettings(jsonData: Data(json.utf8))
        XCTAssertEqual(settings.hexColor(for: .ubuntu), "#00FF00")
        XCTAssertTrue(settings.showsInWhite(for: .ubuntu))
        XCTAssertFalse(settings.showsInWhite(for: .debian))
        XCTAssertEqual(settings.hexColor(for: .debian), BadgeStyle.hexColor(for: .debian))
        XCTAssertFalse(settings.hasCustomAppearance(for: .arch))
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
