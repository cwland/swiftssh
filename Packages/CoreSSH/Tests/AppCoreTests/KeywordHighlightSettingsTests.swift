import XCTest
import Observation
@testable import AppCore

@MainActor
final class KeywordHighlightSettingsTests: XCTestCase {
    private let suite = "KeywordHighlightSettingsTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testCategoriesAndDefaultColours() async {
        XCTAssertEqual(KeywordCategory.allCases, [.error, .warning, .ok, .info, .debug, .network])
        XCTAssertEqual(KeywordCategory.error.defaultColor.hex, "#E06666")
        XCTAssertEqual(KeywordCategory.warning.defaultColor.hex, "#F4C542")
        XCTAssertEqual(KeywordCategory.ok.defaultColor.hex, "#8CCB5E")
        XCTAssertEqual(KeywordCategory.info.defaultColor.hex, "#4A90E2")
        XCTAssertEqual(KeywordCategory.debug.defaultColor.hex, "#8B85F0")
        XCTAssertEqual(KeywordCategory.network.defaultColor.hex, "#C8559E")
        XCTAssertEqual(KeywordCategory.network.displayName, "IP address & MAC")
        XCTAssertEqual(KeywordCategory.ok.displayName, "OK")
    }

    func testKeys() async {
        XCTAssertEqual(KeywordHighlightSettings.enabledKey, "terminal.highlight.enabled")
        XCTAssertEqual(KeywordHighlightSettings.colorKey(for: .error), "terminal.highlight.error")
        XCTAssertEqual(KeywordHighlightSettings.colorKey(for: .network), "terminal.highlight.network")
    }

    func testDefaultsWhenNothingStored() async {
        let settings = KeywordHighlightSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled)
        for category in KeywordCategory.allCases {
            XCTAssertEqual(settings.color(for: category), category.defaultColor)
            XCTAssertTrue(settings.isDefaultColor(for: category))
        }
        XCTAssertEqual(settings.snapshot, .default)
    }

    func testPersistsEnabled() async {
        let settings = KeywordHighlightSettings(defaults: defaults)
        settings.isEnabled = false
        XCTAssertEqual(defaults.object(forKey: KeywordHighlightSettings.enabledKey) as? Bool, false)
        XCTAssertFalse(KeywordHighlightSettings(defaults: defaults).isEnabled)
        XCTAssertFalse(settings.snapshot.isEnabled)
    }

    func testPersistsColourAsHex() async {
        let settings = KeywordHighlightSettings(defaults: defaults)
        let colour = RGBColor(red: 0x12, green: 0xAB, blue: 0xEF)
        settings.setColor(colour, for: .warning)
        XCTAssertEqual(settings.color(for: .warning), colour)
        XCTAssertFalse(settings.isDefaultColor(for: .warning))
        XCTAssertEqual(defaults.string(forKey: "terminal.highlight.warning"), "#12ABEF")
        let reloaded = KeywordHighlightSettings(defaults: defaults)
        XCTAssertEqual(reloaded.color(for: .warning), colour)
        XCTAssertEqual(reloaded.snapshot.color(for: .warning), colour)
        XCTAssertEqual(reloaded.snapshot.color(for: .error), KeywordCategory.error.defaultColor)
    }

    func testInvalidStoredHexFallsBackToDefault() async {
        defaults.set("not a colour", forKey: "terminal.highlight.info")
        XCTAssertEqual(KeywordHighlightSettings(defaults: defaults).color(for: .info), KeywordCategory.info.defaultColor)
    }

    func testResetColours() async {
        let settings = KeywordHighlightSettings(defaults: defaults)
        settings.setColor(RGBColor(red: 1, green: 1, blue: 1), for: .error)
        settings.setColor(RGBColor(red: 2, green: 2, blue: 2), for: .debug)
        settings.resetColor(for: .error)
        XCTAssertEqual(settings.color(for: .error), KeywordCategory.error.defaultColor)
        XCTAssertNil(defaults.object(forKey: "terminal.highlight.error"))
        settings.resetAllColors()
        XCTAssertNil(defaults.object(forKey: "terminal.highlight.debug"))
        XCTAssertEqual(settings.snapshot, .default)
    }

    func testSettingTheDefaultColourRemovesTheKey() async {
        let settings = KeywordHighlightSettings(defaults: defaults)
        settings.setColor(RGBColor(red: 1, green: 1, blue: 1), for: .ok)
        settings.setColor(KeywordCategory.ok.defaultColor, for: .ok)
        XCTAssertNil(defaults.object(forKey: "terminal.highlight.ok"))
    }

    func testObservationFiresOnChange() async {
        let settings = KeywordHighlightSettings(defaults: defaults)
        let colourFired = HighlightObservedFlag()
        withObservationTracking({ _ = settings.snapshot }, onChange: { colourFired.value = true })
        settings.setColor(RGBColor(red: 9, green: 9, blue: 9), for: .info)
        XCTAssertTrue(colourFired.value)

        let enabledFired = HighlightObservedFlag()
        withObservationTracking({ _ = settings.isEnabled }, onChange: { enabledFired.value = true })
        settings.isEnabled = false
        XCTAssertTrue(enabledFired.value)
    }

    func testSnapshotIsUsableOffTheMainActor() async {
        let snapshot = KeywordHighlightSettings(defaults: defaults).snapshot
        let output = await Task.detached {
            let highlighter = KeywordHighlighter(settings: snapshot)
            return highlighter.process(ArraySlice(Array("ok\n".utf8)))
        }.value
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "\u{1B}[38;2;140;203;94mok\u{1B}[39m\n")
    }
}

private final class HighlightObservedFlag: @unchecked Sendable { var value = false }
