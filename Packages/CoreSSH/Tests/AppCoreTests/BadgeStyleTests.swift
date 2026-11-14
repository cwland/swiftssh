import XCTest
import CoreModels
@testable import AppCore

final class BadgeStyleTests: XCTestCase {
    func testBadgeStyleCoversEveryCatalogEntry() {
        for entry in OSCatalog.shared.entries {
            let badge = entry.id
            XCTAssertEqual(BadgeStyle.symbol(for: badge), entry.symbol)
            XCTAssertEqual(BadgeStyle.hexColor(for: badge), entry.hexColor)
            XCTAssertEqual(BadgeStyle.displayName(for: badge), entry.name)
        }
        XCTAssertEqual(BadgeStyle.symbol(for: nil), "terminal")
        XCTAssertEqual(BadgeStyle.hexColor(for: nil), "#5B6475")
        XCTAssertEqual(BadgeStyle.displayName(for: nil), "Automatic")
    }

    func testUnknownIDsAreGenericAndNamedByTheirID() {
        let future = OSBadge(rawValue: "plan9")
        XCTAssertEqual(BadgeStyle.symbol(for: future), "terminal")
        XCTAssertEqual(BadgeStyle.hexColor(for: future), "#5B6475")
        XCTAssertEqual(BadgeStyle.displayName(for: future), "plan9")
    }

    func testExistingSymbolsAndColorsAreKept() {
        XCTAssertEqual(BadgeStyle.symbol(for: .raspbian), "cpu")
        XCTAssertEqual(BadgeStyle.symbol(for: .macos), "desktopcomputer")
        XCTAssertEqual(BadgeStyle.symbol(for: .freebsd), "server.rack")
        XCTAssertEqual(BadgeStyle.symbol(for: .synology), "externaldrive.connected.to.line.below")
        XCTAssertEqual(BadgeStyle.symbol(for: .homeAssistant), "house")
        XCTAssertEqual(BadgeStyle.symbol(for: .ubuntu), "terminal")
        XCTAssertEqual(BadgeStyle.hexColor(for: .ubuntu), "#E2602F")
        XCTAssertEqual(BadgeStyle.hexColor(for: .debian), "#C2275A")
        XCTAssertEqual(BadgeStyle.hexColor(for: .raspbian), "#C2275A")
        XCTAssertEqual(BadgeStyle.hexColor(for: .macos), "#111111")
        XCTAssertEqual(BadgeStyle.hexColor(for: .synology), "#1F4A7A")
        XCTAssertEqual(BadgeStyle.hexColor(for: .homeAssistant), "#2C5D84")
    }

    func testLogoFileNamesAreTheCatalogIDs() {
        XCTAssertEqual(BadgeStyle.logoFileName(for: .raspbian), "raspbian")
        XCTAssertEqual(BadgeStyle.logoFileName(for: .homeAssistant), "home-assistant")
        XCTAssertEqual(BadgeStyle.logoFileNames(for: .ubuntu), ["ubuntu.svg", "ubuntu.png"])
        XCTAssertEqual(BadgeStyle.installedLogoFileName(for: .xcpng), "xcpng.png")
        for entry in OSCatalog.shared.entries {
            XCTAssertEqual(BadgeStyle.logoFileName(for: entry.id), entry.id.rawValue)
        }
    }

    func testIDsThatAreNotSafeFileNamesGetNoLogoFile() {
        for raw in ["../x", "a/b", "", "Ubuntu"] {
            let badge = OSBadge(rawValue: raw)
            XCTAssertNil(BadgeStyle.logoFileName(for: badge), raw)
            XCTAssertEqual(BadgeStyle.logoFileNames(for: badge), [], raw)
            XCTAssertNil(BadgeStyle.installedLogoFileName(for: badge), raw)
        }
    }

    func testLogoFileExtensionsPreferSVG() {
        XCTAssertEqual(BadgeStyle.logoFileExtensions, ["svg", "png"])
        XCTAssertEqual(BadgeStyle.logoFolderName, "Badges")
    }

    func testNewestLogoFileIsReadFirstAndSVGWinsATie() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(BadgeStyle.logoFilesInReadOrder(for: .ubuntu, modified: ["ubuntu.svg": old, "ubuntu.png": new]),
                       ["ubuntu.png", "ubuntu.svg"], "a just-installed PNG wins over a leftover SVG")
        XCTAssertEqual(BadgeStyle.logoFilesInReadOrder(for: .ubuntu, modified: ["ubuntu.svg": new, "ubuntu.png": old]),
                       ["ubuntu.svg", "ubuntu.png"], "an SVG dropped in later wins")
        XCTAssertEqual(BadgeStyle.logoFilesInReadOrder(for: .ubuntu, modified: ["ubuntu.svg": old, "ubuntu.png": old]),
                       ["ubuntu.svg", "ubuntu.png"])
        XCTAssertEqual(BadgeStyle.logoFilesInReadOrder(for: .ubuntu, modified: ["ubuntu.png": old, "debian.svg": new]),
                       ["ubuntu.png"])
        XCTAssertEqual(BadgeStyle.logoFilesInReadOrder(for: OSBadge(rawValue: "../x"), modified: ["../x.png": new]), [])
    }

    func testLegacyRaspberryPiFilesAreRenamedOnlyWhenRaspbianHasNone() {
        XCTAssertEqual(BadgeStyle.logoFileMigrations(existingFileNames: ["raspberry-pi.svg", "ubuntu.png"]),
                       [BadgeStyle.FileRename(from: "raspberry-pi.svg", to: "raspbian.svg")])
        XCTAssertEqual(BadgeStyle.logoFileMigrations(existingFileNames: ["raspberry-pi.svg", "raspberry-pi.png"]),
                       [BadgeStyle.FileRename(from: "raspberry-pi.svg", to: "raspbian.svg"),
                        BadgeStyle.FileRename(from: "raspberry-pi.png", to: "raspbian.png")])
        XCTAssertEqual(BadgeStyle.logoFileMigrations(existingFileNames: ["raspberry-pi.svg", "raspbian.png"]), [],
                       "a newer raspbian logo wins; the old file is left alone")
        XCTAssertEqual(BadgeStyle.logoFileMigrations(existingFileNames: ["ubuntu.svg", "settings.json"]), [])
    }

    func testSettingsRowsFollowTheCatalog() {
        XCTAssertEqual(BadgeStyle.settingsOrder, OSCatalog.shared.entries.map(\.id))
        XCTAssertEqual(BadgeStyle.settingsName(for: .raspbian), "Raspberry Pi OS")
    }
}
