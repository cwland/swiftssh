import XCTest
@testable import AppCore

/// The key bar above the iPhone/iPad software keyboard: sticky Ctrl and Alt, special keys.
@MainActor
final class KeyBarStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: Sticky modifiers

    func testCtrlThenCSendsControlCOnceAndReleases() async {
        let bar = KeyBarState()
        bar.tap(.ctrl, at: t0)
        XCTAssertEqual(bar.state(of: .ctrl), .once)
        XCTAssertTrue(bar.isActive)
        XCTAssertEqual(bar.transform(bytes("c")), [0x03])
        XCTAssertEqual(bar.state(of: .ctrl), .off)
        XCTAssertFalse(bar.isActive)
        XCTAssertEqual(bar.transform(bytes("c")), bytes("c"), "released after one keystroke")
    }

    func testTappingOnceAgainTurnsItOff() async {
        let bar = KeyBarState()
        bar.tap(.ctrl, at: t0)
        bar.tap(.ctrl, at: t0.addingTimeInterval(1))
        XCTAssertEqual(bar.state(of: .ctrl), .off)
    }

    func testDoubleTapLocksUntilTappedAgain() async {
        let bar = KeyBarState()
        bar.tap(.ctrl, at: t0)
        bar.tap(.ctrl, at: t0.addingTimeInterval(0.2))
        XCTAssertEqual(bar.state(of: .ctrl), .locked)
        XCTAssertEqual(bar.transform(bytes("a")), [0x01])
        XCTAssertEqual(bar.transform(bytes("d")), [0x04])
        XCTAssertEqual(bar.state(of: .ctrl), .locked)
        bar.tap(.ctrl, at: t0.addingTimeInterval(5))
        XCTAssertEqual(bar.state(of: .ctrl), .off)
        XCTAssertEqual(bar.transform(bytes("a")), bytes("a"))
    }

    func testTapsJustOverTheIntervalAreNotADoubleTap() async {
        let bar = KeyBarState()
        bar.tap(.alt, at: t0)
        bar.tap(.alt, at: t0.addingTimeInterval(KeyBarState.doubleTapInterval + 0.01))
        XCTAssertEqual(bar.state(of: .alt), .off)
    }

    func testATapAfterUnlockingStartsAFreshOnce() async {
        let bar = KeyBarState()
        bar.tap(.ctrl, at: t0)
        bar.tap(.ctrl, at: t0.addingTimeInterval(0.1)) // locked
        bar.tap(.ctrl, at: t0.addingTimeInterval(0.2)) // off
        bar.tap(.ctrl, at: t0.addingTimeInterval(0.3)) // once again, not locked
        XCTAssertEqual(bar.state(of: .ctrl), .once)
    }

    func testControlCodesForLettersAndSymbols() async {
        let bar = KeyBarState()
        let cases: [(String, UInt8)] = [("A", 0x01), ("z", 0x1A), ("@", 0x00), ("[", 0x1B), ("\\", 0x1C),
                                         ("]", 0x1D), ("^", 0x1E), ("_", 0x1F), (" ", 0x00), ("?", 0x7F)]
        for (text, code) in cases {
            bar.tap(.ctrl, at: t0)
            XCTAssertEqual(bar.transform(bytes(text)), [code], text)
        }
        bar.tap(.ctrl, at: t0)
        XCTAssertEqual(bar.transform(bytes("1")), bytes("1"), "no control code: sent as typed")
        XCTAssertEqual(bar.state(of: .ctrl), .off, "the keystroke still uses up a one-shot Ctrl")
    }

    func testAltPrefixesEscape() async {
        let bar = KeyBarState()
        bar.tap(.alt, at: t0)
        XCTAssertEqual(bar.transform(bytes("b")), [0x1B] + bytes("b"))
        XCTAssertEqual(bar.state(of: .alt), .off)
    }

    func testCtrlAndAltTogether() async {
        let bar = KeyBarState()
        bar.tap(.ctrl, at: t0)
        bar.tap(.alt, at: t0)
        XCTAssertEqual(bar.transform(bytes("x")), [0x1B, 0x18])
        XCTAssertFalse(bar.isActive)
    }

    func testLockedAltStaysWhileOnceCtrlIsUsedUp() async {
        let bar = KeyBarState()
        bar.tap(.alt, at: t0)
        bar.tap(.alt, at: t0.addingTimeInterval(0.1))
        bar.tap(.ctrl, at: t0.addingTimeInterval(1))
        _ = bar.transform(bytes("a"))
        XCTAssertEqual(bar.state(of: .ctrl), .off)
        XCTAssertEqual(bar.state(of: .alt), .locked)
    }

    func testEmptyInputChangesNothing() async {
        let bar = KeyBarState()
        bar.tap(.ctrl, at: t0)
        XCTAssertEqual(bar.transform([]), [])
        XCTAssertEqual(bar.state(of: .ctrl), .once)
    }

    func testReleaseAllTurnsEverythingOff() async {
        let bar = KeyBarState()
        bar.tap(.ctrl, at: t0)
        bar.tap(.ctrl, at: t0.addingTimeInterval(0.1))
        bar.tap(.alt, at: t0)
        bar.releaseAll()
        XCTAssertEqual(bar.state(of: .ctrl), .off)
        XCTAssertEqual(bar.state(of: .alt), .off)
    }

    // MARK: Keys

    func testEscTabAndSymbols() async {
        let bar = KeyBarState()
        XCTAssertEqual(bar.bytes(for: .escape, applicationCursor: false), [0x1B])
        XCTAssertEqual(bar.bytes(for: .tab, applicationCursor: false), [0x09])
        XCTAssertEqual(bar.bytes(for: .text("|"), applicationCursor: false), bytes("|"))
        bar.tap(.ctrl, at: t0)
        XCTAssertEqual(bar.bytes(for: .text("_"), applicationCursor: false), [0x1F])
        bar.tap(.alt, at: t0)
        XCTAssertEqual(bar.bytes(for: .escape, applicationCursor: false), [0x1B, 0x1B])
    }

    func testArrowsHonourApplicationCursorMode() async {
        let bar = KeyBarState()
        XCTAssertEqual(bar.bytes(for: .up, applicationCursor: false), bytes("\u{1B}[A"))
        XCTAssertEqual(bar.bytes(for: .down, applicationCursor: true), bytes("\u{1B}OB"))
        XCTAssertEqual(bar.bytes(for: .right, applicationCursor: false), bytes("\u{1B}[C"))
        XCTAssertEqual(bar.bytes(for: .left, applicationCursor: true), bytes("\u{1B}OD"))
        XCTAssertEqual(bar.bytes(for: .home, applicationCursor: false), bytes("\u{1B}[H"))
        XCTAssertEqual(bar.bytes(for: .end, applicationCursor: true), bytes("\u{1B}OF"))
        XCTAssertEqual(bar.bytes(for: .pageUp, applicationCursor: true), bytes("\u{1B}[5~"))
        XCTAssertEqual(bar.bytes(for: .pageDown, applicationCursor: false), bytes("\u{1B}[6~"))
    }

    func testModifiedArrowsUseXtermParameters() async {
        let bar = KeyBarState()
        bar.tap(.ctrl, at: t0)
        XCTAssertEqual(bar.bytes(for: .left, applicationCursor: true), bytes("\u{1B}[1;5D"))
        XCTAssertEqual(bar.state(of: .ctrl), .off)
        bar.tap(.alt, at: t0)
        XCTAssertEqual(bar.bytes(for: .right, applicationCursor: false), bytes("\u{1B}[1;3C"))
        bar.tap(.ctrl, at: t0)
        bar.tap(.alt, at: t0)
        XCTAssertEqual(bar.bytes(for: .pageUp, applicationCursor: false), bytes("\u{1B}[5;7~"))
    }

    func testTheBarsKeysInOrder() async {
        XCTAssertEqual(KeyBarState.Key.bar.first, .escape)
        XCTAssertTrue(KeyBarState.Key.bar.contains(.text("~")))
        for symbol in ["|", "/", "-", "~", "_"] {
            XCTAssertTrue(KeyBarState.Key.bar.contains(.text(symbol)), symbol)
        }
        for key in KeyBarState.Key.bar {
            XCTAssertFalse(key.title.isEmpty)
            XCTAssertFalse(key.accessibilityLabel.isEmpty)
        }
    }
}
