import XCTest
import CoreModels
@testable import AppCore

final class BadgeStyleTests: XCTestCase {
    func testBadgeStyleCoversEveryOSBadge() {
        for badge in OSBadge.allCases {
            XCTAssertFalse(BadgeStyle.symbol(for: badge).isEmpty, "\(badge)")
            let color = BadgeStyle.hexColor(for: badge)
            XCTAssertEqual(color.count, 7, "\(badge)")
            XCTAssertTrue(color.hasPrefix("#"), "\(badge)")
            XCTAssertTrue(color.dropFirst().allSatisfy(\.isHexDigit), "\(badge)")
        }
        XCTAssertEqual(BadgeStyle.symbol(for: nil), "terminal")
        XCTAssertEqual(BadgeStyle.hexColor(for: nil).count, 7)
    }

    func testSpecificSymbolsAndColors() {
        XCTAssertEqual(BadgeStyle.symbol(for: .raspberryPiOS), "cpu")
        XCTAssertEqual(BadgeStyle.symbol(for: .macOS), "desktopcomputer")
        XCTAssertEqual(BadgeStyle.symbol(for: .freeBSD), "server.rack")
        XCTAssertEqual(BadgeStyle.symbol(for: .synology), "externaldrive.connected.to.line.below")
        XCTAssertEqual(BadgeStyle.symbol(for: .homeAssistant), "house")
        XCTAssertEqual(BadgeStyle.hexColor(for: .ubuntu), "#E2602F")
        XCTAssertEqual(BadgeStyle.hexColor(for: .debian), "#C2275A")
        XCTAssertEqual(BadgeStyle.hexColor(for: .raspberryPiOS), "#C2275A")
        XCTAssertEqual(BadgeStyle.hexColor(for: .macOS), "#111111")
        XCTAssertEqual(BadgeStyle.hexColor(for: .synology), "#1F4A7A")
        XCTAssertEqual(BadgeStyle.hexColor(for: .homeAssistant), "#2C5D84")
        XCTAssertEqual(BadgeStyle.hexColor(for: .fedora), "#5B6475")
    }

    func testLogoFileNameForEveryBadge() {
        let expected: [OSBadge: String] = [
            .ubuntu: "ubuntu", .debian: "debian", .raspberryPiOS: "raspberry-pi", .fedora: "fedora",
            .rhel: "rhel", .alpine: "alpine", .arch: "arch", .macOS: "macos", .freeBSD: "freebsd",
            .linux: "linux", .synology: "synology", .homeAssistant: "home-assistant",
        ]
        XCTAssertEqual(Set(expected.keys), Set(OSBadge.allCases))
        for badge in OSBadge.allCases {
            XCTAssertEqual(BadgeStyle.logoFileName(for: badge), expected[badge], "\(badge)")
        }
        XCTAssertEqual(Set(OSBadge.allCases.map { BadgeStyle.logoFileName(for: $0) }).count, OSBadge.allCases.count)
    }

    func testLogoFileExtensionsPreferSVG() {
        XCTAssertEqual(BadgeStyle.logoFileExtensions, ["svg", "png"])
        XCTAssertEqual(BadgeStyle.logoFolderName, "Badges")
    }
}
