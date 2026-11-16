import XCTest
import Observation
@testable import AppCore
import SSHCore

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

    // MARK: Behaviour (v0.6.1)

    func testBehaviourDefaults() async {
        let settings = TerminalSettings(defaults: defaults)
        XCTAssertNil(settings.fontName, "SF Mono")
        XCTAssertTrue(settings.opensLinksWithCommandClick)
        XCTAssertFalse(settings.selectToCopyRightClickToPaste)
        XCTAssertFalse(settings.bellSound)
        XCTAssertTrue(settings.optionAsMetaKey)
        XCTAssertFalse(settings.boldUsesBrightColors)
        XCTAssertEqual(settings.terminalType, .xterm256color)
        XCTAssertEqual(settings.behaviour, TerminalBehaviour())
        XCTAssertEqual(TerminalBehaviour(), TerminalBehaviour(opensLinks: true, selectToCopyRightClickToPaste: false,
                                                              bellSound: false, optionAsMetaKey: true,
                                                              boldUsesBrightColors: false))
    }

    func testBehaviourKeys() async {
        XCTAssertEqual(TerminalSettings.fontNameKey, "terminal.fontName")
        XCTAssertEqual(TerminalSettings.openLinksKey, "terminal.openLinksWithCommandClick")
        XCTAssertEqual(TerminalSettings.selectToCopyKey, "terminal.selectToCopyRightClickToPaste")
        XCTAssertEqual(TerminalSettings.bellSoundKey, "terminal.bellSound")
        XCTAssertEqual(TerminalSettings.optionAsMetaDefaultsKey, "terminal.optionAsMetaKey")
        XCTAssertEqual(TerminalSettings.boldBrightKey, "terminal.boldUsesBrightColors")
        XCTAssertEqual(TerminalSettings.terminalTypeKey, "terminal.terminalType")
    }

    func testTogglesPersist() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.opensLinksWithCommandClick = false
        settings.selectToCopyRightClickToPaste = true
        settings.bellSound = true
        settings.optionAsMetaKey = false
        settings.boldUsesBrightColors = true
        XCTAssertEqual(defaults.object(forKey: TerminalSettings.openLinksKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: TerminalSettings.bellSoundKey) as? Bool, true)

        let reloaded = TerminalSettings(defaults: defaults)
        XCTAssertFalse(reloaded.opensLinksWithCommandClick)
        XCTAssertTrue(reloaded.selectToCopyRightClickToPaste)
        XCTAssertTrue(reloaded.bellSound)
        XCTAssertFalse(reloaded.optionAsMetaKey)
        XCTAssertTrue(reloaded.boldUsesBrightColors)
        XCTAssertEqual(reloaded.behaviour, TerminalBehaviour(opensLinks: false, selectToCopyRightClickToPaste: true,
                                                             bellSound: true, optionAsMetaKey: false,
                                                             boldUsesBrightColors: true))
    }

    func testTerminalTypePersistsAndUnknownStoredValueIsTheDefault() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.terminalType = .vt100
        XCTAssertEqual(defaults.string(forKey: TerminalSettings.terminalTypeKey), "vt100")
        XCTAssertEqual(TerminalSettings(defaults: defaults).terminalType, .vt100)

        defaults.set("wyse60", forKey: TerminalSettings.terminalTypeKey)
        XCTAssertEqual(TerminalSettings(defaults: defaults).terminalType, .xterm256color)
    }

    func testFontNamePersistsAndEmptyMeansSFMono() async {
        let settings = TerminalSettings(defaults: defaults)
        settings.fontName = "Menlo"
        XCTAssertEqual(settings.fontName, "Menlo")
        XCTAssertEqual(TerminalSettings(defaults: defaults).fontName, "Menlo")

        settings.fontName = ""
        XCTAssertNil(settings.fontName)
        XCTAssertNil(defaults.object(forKey: TerminalSettings.fontNameKey))

        settings.fontName = "Menlo"
        settings.fontName = nil
        XCTAssertNil(TerminalSettings(defaults: defaults).fontName)

        defaults.set("", forKey: TerminalSettings.fontNameKey)
        XCTAssertNil(TerminalSettings(defaults: defaults).fontName)
    }

    func testAppearanceCarriesThemeSizeFontAndBehaviour() async throws {
        let settings = TerminalSettings(defaults: defaults)
        let theme = try XCTUnwrap(TerminalThemeCatalog.shared.theme(id: "nord"))
        settings.fontSize = 15
        settings.fontName = "Menlo"
        settings.bellSound = true
        let appearance = settings.appearance(theme: theme)
        XCTAssertEqual(appearance.theme, theme)
        XCTAssertEqual(appearance.fontSize, 15)
        XCTAssertEqual(appearance.fontName, "Menlo")
        XCTAssertEqual(appearance.behaviour, settings.behaviour)
        XCTAssertTrue(appearance.behaviour.bellSound)
    }

    func testAppearanceDefaultsKeepTheOldInitializer() async throws {
        let theme = try XCTUnwrap(TerminalThemeCatalog.shared.theme(id: "nord"))
        let appearance = TerminalAppearance(theme: theme, fontSize: 13)
        XCTAssertNil(appearance.fontName)
        XCTAssertEqual(appearance.behaviour, TerminalBehaviour())
    }

    func testBehaviourChangesAreObservable() async {
        let settings = TerminalSettings(defaults: defaults)
        let fired = ObservedFlag()
        withObservationTracking({ _ = settings.behaviour }, onChange: { fired.value = true })
        settings.bellSound = true
        XCTAssertTrue(fired.value)

        let fontFired = ObservedFlag()
        withObservationTracking({ _ = settings.appearance(theme: TerminalThemeCatalog.shared.automatic(prefersDark: true)) },
                                onChange: { fontFired.value = true })
        settings.fontName = "Menlo"
        XCTAssertTrue(fontFired.value)

        let typeFired = ObservedFlag()
        withObservationTracking({ _ = settings.terminalType }, onChange: { typeFired.value = true })
        settings.terminalType = .linux
        XCTAssertTrue(typeFired.value)
    }

    // MARK: Fonts

    func testPreferredMemberIsTheRegularFace() async {
        let members = [
            TerminalFontChoice.Member(name: "Fira-Bold", weight: 9, isBold: true, isItalic: false),
            TerminalFontChoice.Member(name: "Fira-Regular", weight: 5, isBold: false, isItalic: false),
            TerminalFontChoice.Member(name: "Fira-Italic", weight: 5, isBold: false, isItalic: true),
        ]
        XCTAssertEqual(TerminalFontChoice.preferredMember(members), "Fira-Regular")
    }

    func testPreferredMemberWithoutARegularWeightTakesTheNearestUprightOne() async {
        let members = [
            TerminalFontChoice.Member(name: "Mono-Heavy", weight: 11, isBold: true, isItalic: false),
            TerminalFontChoice.Member(name: "Mono-LightItalic", weight: 4, isBold: false, isItalic: true),
            TerminalFontChoice.Member(name: "Mono-Light", weight: 3, isBold: false, isItalic: false),
            TerminalFontChoice.Member(name: "Mono-Medium", weight: 6, isBold: false, isItalic: false),
        ]
        XCTAssertEqual(TerminalFontChoice.preferredMember(members), "Mono-Medium")
    }

    func testPreferredMemberFallsBackToAnyFace() async {
        XCTAssertEqual(TerminalFontChoice.preferredMember([
            TerminalFontChoice.Member(name: "Only-BoldItalic", weight: 9, isBold: true, isItalic: true),
        ]), "Only-BoldItalic")
        XCTAssertNil(TerminalFontChoice.preferredMember([]))
    }

    // MARK: Select to copy

    func testCopiesOnlyANewSelectionAndNotWhileTheProgramTracksTheMouse() async {
        XCTAssertTrue(SelectionCopyRule.shouldCopy(before: nil, after: "word", programTracksMouse: false))
        XCTAssertTrue(SelectionCopyRule.shouldCopy(before: "old", after: "new", programTracksMouse: false))
        XCTAssertFalse(SelectionCopyRule.shouldCopy(before: "same", after: "same", programTracksMouse: false),
                       "a click that leaves the selection as it was (e.g. in a mouse-tracking program) doesn't re-copy")
        XCTAssertFalse(SelectionCopyRule.shouldCopy(before: nil, after: nil, programTracksMouse: false))
        XCTAssertFalse(SelectionCopyRule.shouldCopy(before: nil, after: "", programTracksMouse: false))
        XCTAssertFalse(SelectionCopyRule.shouldCopy(before: nil, after: "word", programTracksMouse: true))
    }

    func testFontListIsSortedUniqueAndSkipsHiddenFamilies() async {
        let list = TerminalFontChoice.pickerFamilies(fixedPitch: ["Menlo", ".AppleSystemUIFontMonospaced", "courier",
                                                                  "Andale Mono", "Menlo", "", "SF Mono"])
        XCTAssertEqual(list, ["Andale Mono", "courier", "Menlo"],
                       "SF Mono is the first row on its own (nil), so it is not listed again")
    }
}

private final class ObservedFlag: @unchecked Sendable { var value = false }
