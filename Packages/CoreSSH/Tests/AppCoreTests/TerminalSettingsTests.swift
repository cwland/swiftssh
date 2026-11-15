import XCTest
import Observation
@testable import AppCore

@MainActor
final class TerminalSettingsTests: XCTestCase {
    private let suite = "TerminalSettingsTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsWhenNothingStored() async {
        let settings = TerminalSettings(defaults: defaults)
        XCTAssertNil(settings.defaultThemeID)
        XCTAssertEqual(settings.fontSize, 13)
        XCTAssertEqual(TerminalSettings.defaultFontSize, 13)
        XCTAssertEqual(TerminalSettings.fontSizeRange, 9...24)
        XCTAssertEqual(TerminalSettings.defaultThemeKey, "terminal.defaultThemeID")
        XCTAssertEqual(TerminalSettings.fontSizeKey, "terminal.fontSize")
    }

    func testPersistsDefaultThemeID() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.defaultThemeID = "dracula"
        XCTAssertEqual(settings.defaultThemeID, "dracula")
        XCTAssertEqual(defaults.string(forKey: TerminalSettings.defaultThemeKey), "dracula")
        XCTAssertEqual(TerminalSettings(defaults: defaults).defaultThemeID, "dracula")
    }

    func testSettingNilRemovesKey() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.defaultThemeID = "nord"
        settings.defaultThemeID = nil
        XCTAssertNil(settings.defaultThemeID)
        XCTAssertNil(defaults.object(forKey: TerminalSettings.defaultThemeKey))
        XCTAssertNil(TerminalSettings(defaults: defaults).defaultThemeID)
    }

    func testIgnoresUnknownThemeIDOnSet() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.defaultThemeID = "nord"
        settings.defaultThemeID = "no-such-theme"
        XCTAssertEqual(settings.defaultThemeID, "nord")
        XCTAssertEqual(defaults.string(forKey: TerminalSettings.defaultThemeKey), "nord")

        let fresh = TerminalSettings(defaults: UserDefaults(suiteName: suite + ".fresh")!)
        defer { UserDefaults().removePersistentDomain(forName: suite + ".fresh") }
        fresh.defaultThemeID = "no-such-theme"
        XCTAssertNil(fresh.defaultThemeID)
    }

    func testUnknownStoredThemeIDReadsAsAutomatic() async {
        defaults.set("theme-from-a-newer-build", forKey: TerminalSettings.defaultThemeKey)
        XCTAssertNil(TerminalSettings(defaults: defaults).defaultThemeID)
    }

    func testFontSizeClampedOnSetAndRead() async {
        defaults.set(99, forKey: TerminalSettings.fontSizeKey)
        XCTAssertEqual(TerminalSettings(defaults: defaults).fontSize, 24)
        defaults.set(3, forKey: TerminalSettings.fontSizeKey)
        XCTAssertEqual(TerminalSettings(defaults: defaults).fontSize, 9)

        let settings = TerminalSettings(defaults: defaults)
        settings.fontSize = 40
        XCTAssertEqual(settings.fontSize, 24)
        XCTAssertEqual(defaults.integer(forKey: TerminalSettings.fontSizeKey), 24)
        settings.fontSize = -2
        XCTAssertEqual(settings.fontSize, 9)
        XCTAssertEqual(defaults.integer(forKey: TerminalSettings.fontSizeKey), 9)
    }

    func testIncreaseDecreaseStopAtBounds() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.increaseFontSize()
        XCTAssertEqual(settings.fontSize, 14)
        settings.decreaseFontSize()
        settings.decreaseFontSize()
        XCTAssertEqual(settings.fontSize, 12)

        settings.fontSize = 24
        settings.increaseFontSize()
        XCTAssertEqual(settings.fontSize, 24)
        settings.fontSize = 9
        settings.decreaseFontSize()
        XCTAssertEqual(settings.fontSize, 9)
    }

    func testCanIncreaseCanDecrease() async {
        let settings = TerminalSettings(defaults: defaults)
        XCTAssertTrue(settings.canIncreaseFontSize)
        XCTAssertTrue(settings.canDecreaseFontSize)
        settings.fontSize = 24
        XCTAssertFalse(settings.canIncreaseFontSize)
        XCTAssertTrue(settings.canDecreaseFontSize)
        settings.fontSize = 9
        XCTAssertTrue(settings.canIncreaseFontSize)
        XCTAssertFalse(settings.canDecreaseFontSize)
    }

    func testFontSizePersists() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.fontSize = 17
        XCTAssertEqual(TerminalSettings(defaults: defaults).fontSize, 17)
        settings.increaseFontSize()
        XCTAssertEqual(TerminalSettings(defaults: defaults).fontSize, 18)
    }

    func testResetFontSizeReturnsTo13() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.fontSize = 20
        settings.resetFontSize()
        XCTAssertEqual(settings.fontSize, 13)
        XCTAssertEqual(TerminalSettings(defaults: defaults).fontSize, 13)
        settings.resetFontSize()
        XCTAssertEqual(settings.fontSize, 13)
    }

    func testChangesAreObservable() async {
        let settings = TerminalSettings(defaults: defaults)
        let sizeFired = ObservedFlag()
        withObservationTracking({ _ = settings.fontSize }, onChange: { sizeFired.value = true })
        settings.fontSize = 15
        XCTAssertTrue(sizeFired.value)

        let themeFired = ObservedFlag()
        withObservationTracking({ _ = settings.defaultThemeID }, onChange: { themeFired.value = true })
        settings.defaultThemeID = "aura"
        XCTAssertTrue(themeFired.value)
    }
}

private final class ObservedFlag: @unchecked Sendable { var value = false }
