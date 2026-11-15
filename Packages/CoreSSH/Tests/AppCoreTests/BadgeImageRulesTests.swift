import XCTest
import Foundation
import CoreModels
@testable import AppCore

final class BadgeImageRulesTests: XCTestCase {
    func testWebLinkValidation() throws {
        XCTAssertEqual(try BadgeImageRules.webURL(from: " https://example.com/logo.svg ").absoluteString,
                       "https://example.com/logo.svg")
        XCTAssertEqual(try BadgeImageRules.webURL(from: "HTTP://example.com/a.png").host, "example.com")
        for bad in ["", "   ", "example.com/logo.png", "ftp://example.com/a.png", "file:///etc/passwd",
                    "javascript:alert(1)", "data:image/png;base64,AAAA", "https://", "http:///path",
                    "https://exa mple.com/a.png"] {
            XCTAssertThrowsError(try BadgeImageRules.webURL(from: bad), bad) { error in
                XCTAssertEqual(error as? BadgeImageError, .notAWebLink, bad)
            }
        }
    }

    func testSizeLimit() {
        XCTAssertEqual(BadgeImageRules.maximumDownloadBytes, 2 * 1024 * 1024)
        XCTAssertNil(BadgeImageRules.problem(contentLength: nil))
        XCTAssertNil(BadgeImageRules.problem(contentLength: -1), "unknown length")
        XCTAssertNil(BadgeImageRules.problem(contentLength: 2 * 1024 * 1024))
        XCTAssertEqual(BadgeImageRules.problem(contentLength: 2 * 1024 * 1024 + 1), .tooLarge)
        XCTAssertTrue(BadgeImageRules.exceedsLimit(byteCount: 2 * 1024 * 1024 + 1))
        XCTAssertFalse(BadgeImageRules.exceedsLimit(byteCount: 2 * 1024 * 1024))
        XCTAssertEqual(BadgeImageRules.downloadTimeout, 15)
    }

    func testHTTPStatus() {
        XCTAssertNil(BadgeImageRules.problem(httpStatus: 200))
        XCTAssertNil(BadgeImageRules.problem(httpStatus: 204))
        XCTAssertEqual(BadgeImageRules.problem(httpStatus: 404), .downloadFailed("the server answered 404"))
        XCTAssertEqual(BadgeImageRules.problem(httpStatus: 301), .downloadFailed("the server answered 301"))
    }

    func testMessages() {
        XCTAssertEqual(BadgeImageError.notAnImage.message, "That link isn't an image.")
        XCTAssertEqual(BadgeImageError.notAnImageFile.message, "That file isn't an image.")
        XCTAssertEqual(BadgeImageError.tooLarge.message, "That image is larger than 2 MB.")
        XCTAssertEqual(BadgeImageError.downloadFailed("the request timed out").message,
                       "Couldn't download it: the request timed out")
        XCTAssertEqual(BadgeImageError.notAWebLink.message, "Enter a link that starts with http:// or https://.")
        XCTAssertEqual(BadgeImageError.couldNotSave("disk full").message, "Couldn't save the image: disk full")
    }

    func testAspectFitRect() throws {
        XCTAssertEqual(BadgeImageRules.canvasPixels, 256)
        XCTAssertEqual(BadgeImageRules.paddingFraction, 0.12)
        // Square image: 12% padding on every side.
        let square = try XCTUnwrap(BadgeImageRules.fitRect(imageSize: CGSize(width: 50, height: 50), canvas: 100))
        XCTAssertEqual(square, CGRect(x: 12, y: 12, width: 76, height: 76))
        // Wide image: full inner width, centered vertically.
        let wide = try XCTUnwrap(BadgeImageRules.fitRect(imageSize: CGSize(width: 400, height: 100), canvas: 100))
        XCTAssertEqual(wide.width, 76, accuracy: 1e-9)
        XCTAssertEqual(wide.height, 19, accuracy: 1e-9)
        XCTAssertEqual(wide.minX, 12, accuracy: 1e-9)
        XCTAssertEqual(wide.midY, 50, accuracy: 1e-9)
        // Tall image: full inner height, centered horizontally.
        let tall = try XCTUnwrap(BadgeImageRules.fitRect(imageSize: CGSize(width: 10, height: 20), canvas: 256))
        XCTAssertEqual(tall.height, 256 * 0.76, accuracy: 1e-9)
        XCTAssertEqual(tall.width, 256 * 0.38, accuracy: 1e-9)
        XCTAssertEqual(tall.midX, 128, accuracy: 1e-9)
        XCTAssertEqual(tall.minY, 256 * 0.12, accuracy: 1e-9)
        // Tiny images scale up too.
        let tiny = try XCTUnwrap(BadgeImageRules.fitRect(imageSize: CGSize(width: 1, height: 1), canvas: 256))
        XCTAssertEqual(tiny.width, 256 * 0.76, accuracy: 1e-9)
        // Unusable sizes.
        XCTAssertNil(BadgeImageRules.fitRect(imageSize: CGSize(width: 0, height: 10), canvas: 256))
        XCTAssertNil(BadgeImageRules.fitRect(imageSize: CGSize(width: 10, height: -1), canvas: 256))
        XCTAssertNil(BadgeImageRules.fitRect(imageSize: CGSize(width: CGFloat.nan, height: 10), canvas: 256))
        XCTAssertNil(BadgeImageRules.fitRect(imageSize: CGSize(width: CGFloat.infinity, height: 10), canvas: 256))
        XCTAssertNil(BadgeImageRules.fitRect(imageSize: CGSize(width: 10, height: 10), canvas: 0))
    }

    func testFileNaming() {
        XCTAssertEqual(BadgeStyle.installedLogoFileName(for: .ubuntu), "ubuntu.png")
        XCTAssertEqual(BadgeStyle.installedLogoFileName(for: .homeAssistant), "home-assistant.png")
        XCTAssertEqual(BadgeStyle.logoFileNames(for: .raspbian), ["raspbian.svg", "raspbian.png"])
        XCTAssertEqual(BadgeStyle.settingsFileName, "settings.json")
        XCTAssertEqual(BadgeImageRules.allowedFileExtensions, ["svg", "png", "jpg", "jpeg", "pdf"])
    }

    func testDecodeLimits() {
        XCTAssertEqual(BadgeImageRules.maximumDecodePixelSize, 1024)
        XCTAssertEqual(BadgeImageRules.maximumSourcePixels, 50_000_000)
        XCTAssertNil(BadgeImageRules.problem(pixelWidth: 4000, pixelHeight: 3000))
        XCTAssertNil(BadgeImageRules.problem(pixelWidth: 10_000, pixelHeight: 5_000))
        XCTAssertEqual(BadgeImageRules.problem(pixelWidth: 10_000, pixelHeight: 5_001), .tooManyPixels)
        XCTAssertEqual(BadgeImageRules.problem(pixelWidth: 100_000, pixelHeight: 100_000), .tooManyPixels)
        XCTAssertEqual(BadgeImageRules.problem(pixelWidth: Int.max, pixelHeight: Int.max), .tooManyPixels, "no overflow")
        XCTAssertEqual(BadgeImageRules.problem(pixelWidth: 0, pixelHeight: 10), .notAnImage)
        XCTAssertEqual(BadgeImageRules.problem(pixelWidth: -1, pixelHeight: 10), .notAnImage)
        XCTAssertNil(BadgeImageRules.problem(pixelWidth: nil, pixelHeight: nil), "unknown: the thumbnail limit still applies")
    }

    func testImageKindSniffing() {
        func kind(_ text: String) -> BadgeImageRules.ImageKind { BadgeImageRules.kind(of: Data(text.utf8)) }
        XCTAssertEqual(kind("%PDF-1.7\n..."), .vector)
        XCTAssertEqual(kind("<svg xmlns=\"http://www.w3.org/2000/svg\"/>"), .vector)
        XCTAssertEqual(kind("\u{FEFF}  \n<?xml version=\"1.0\"?>\n<!-- c -->\n<SVG viewBox=\"0 0 1 1\"></SVG>"), .vector)
        XCTAssertEqual(kind("<!DOCTYPE html><html><body><svg></svg></body></html>"), .bitmap, "a web page is not an SVG")
        XCTAssertEqual(kind("<html><svg/></html>"), .bitmap)
        XCTAssertEqual(BadgeImageRules.kind(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), .bitmap)
        XCTAssertEqual(BadgeImageRules.kind(of: Data([0xFF, 0xD8, 0xFF])), .bitmap)
        XCTAssertEqual(BadgeImageRules.kind(of: Data()), .bitmap)
        let late = String(repeating: " ", count: 5000) + "<svg/>"
        XCTAssertEqual(kind(late), .bitmap, "only the start of the file is looked at")
    }

    func testNewErrorMessages() {
        XCTAssertEqual(BadgeImageError.tooManyPixels.message, "That image has too many pixels (over 50 megapixels).")
        XCTAssertEqual(BadgeImageError.oldFileNotRemoved(name: "ubuntu.svg", reason: "denied").message,
                       "The new image is saved and shown, but the old ubuntu.svg couldn't be removed (denied). You can delete it in Finder.")
    }

    func testCouldNotReadMessage() {
        XCTAssertEqual(BadgeImageError.couldNotRead("no permission").message, "Couldn't read that file: no permission")
    }

    func testSettingsPanes() {
        XCTAssertEqual(SettingsPane.allCases, [.connection, .terminal, .sync, .onePassword, .osIcons, .recentlyDeleted])
        XCTAssertEqual(SettingsPane.recentlyDeleted.title, "Recently Deleted")
        XCTAssertEqual(SettingsPane.recentlyDeleted.systemImage, "trash")
        XCTAssertEqual(SettingsPane.terminal.title, "Terminal")
        XCTAssertEqual(SettingsPane.terminal.systemImage, "terminal")
        XCTAssertEqual(SettingsPane.sync.title, "Sync")
        XCTAssertEqual(SettingsPane.sync.systemImage, "arrow.triangle.2.circlepath.icloud")
        XCTAssertEqual(SettingsPane.onePassword.title, "1Password")
        XCTAssertEqual(SettingsPane.onePassword.systemImage, "key.horizontal")
        XCTAssertEqual(SettingsPane.connection.title, "Connection")
        XCTAssertEqual(SettingsPane.connection.systemImage, "antenna.radiowaves.left.and.right")
        XCTAssertEqual(SettingsPane.osIcons.title, "OS Icons")
        XCTAssertFalse(SettingsPane.osIcons.systemImage.isEmpty)
    }
}
