import XCTest
@testable import AppCore

final class RGBColorTests: XCTestCase {
    func testParsesHashAndBareHexAnyCase() {
        let expected = RGBColor(red: 0xAB, green: 0xCD, blue: 0xEF)
        XCTAssertEqual(RGBColor(hex: "#ABCDEF"), expected)
        XCTAssertEqual(RGBColor(hex: "abcdef"), expected)
        XCTAssertEqual(RGBColor(hex: "#aBcDeF"), expected)
        XCTAssertEqual(RGBColor(hex: "  #abcdef \n"), expected)
        XCTAssertEqual(RGBColor(hex: "#000000"), RGBColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(RGBColor(hex: "FFFFFF"), RGBColor(red: 255, green: 255, blue: 255))
    }

    func testRejectsMalformedHex() {
        for bad in ["", "#12345", "#1234567", "GGGGGG", "#12 456", "#", "##123456", "+12345", "0x1234"] {
            XCTAssertNil(RGBColor(hex: bad), bad)
        }
    }

    func testHexIsUppercaseWithHash() {
        XCTAssertEqual(RGBColor(red: 0xab, green: 0x0c, blue: 0xef).hex, "#AB0CEF")
        XCTAssertEqual(RGBColor(hex: "ff79c6")?.hex, "#FF79C6")
    }

    func testRelativeLuminanceOfBlackAndWhite() {
        XCTAssertEqual(RGBColor(red: 0, green: 0, blue: 0).relativeLuminance, 0, accuracy: 1e-9)
        XCTAssertEqual(RGBColor(red: 255, green: 255, blue: 255).relativeLuminance, 1, accuracy: 1e-9)
        // sRGB mid grey (#777777) is about 0.184.
        XCTAssertEqual(RGBColor(red: 0x77, green: 0x77, blue: 0x77).relativeLuminance, 0.1845, accuracy: 0.001)
    }

    func testContrastRatioBlackWhiteIs21() {
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 255, green: 255, blue: 255)
        XCTAssertEqual(black.contrastRatio(with: white), 21, accuracy: 1e-9)
        XCTAssertEqual(white.contrastRatio(with: white), 1, accuracy: 1e-9)
    }

    func testContrastRatioIsSymmetric() {
        let a = RGBColor(hex: "#282A36")!
        let b = RGBColor(hex: "#F8F8F2")!
        XCTAssertEqual(a.contrastRatio(with: b), b.contrastRatio(with: a), accuracy: 1e-12)
        XCTAssertGreaterThan(a.contrastRatio(with: b), 1)
    }
}
