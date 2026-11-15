import XCTest
@testable import AppCore

@MainActor
final class AppAppearanceSettingTests: XCTestCase {
    private let suite = "AppAppearanceSettingTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOptionsAndTitles() async {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppAppearance.allCases.map(\.title), ["System", "Light", "Dark"])
    }

    func testDefaultsToSystem() async {
        XCTAssertEqual(AppAppearanceSetting(defaults: defaults).appearance, .system)
    }

    func testPersistsUnderTheDocumentedKey() async {
        let setting = AppAppearanceSetting(defaults: defaults)
        setting.appearance = .dark
        XCTAssertEqual(defaults.string(forKey: "app.appearance"), "dark")
        XCTAssertEqual(AppAppearanceSetting(defaults: defaults).appearance, .dark)
    }

    func testUnknownStoredValueIsSystem() async {
        defaults.set("sepia", forKey: "app.appearance")
        XCTAssertEqual(AppAppearanceSetting(defaults: defaults).appearance, .system)
    }

    func testChangeHandlerRunsOnChangeOnly() async {
        let setting = AppAppearanceSetting(defaults: defaults)
        var seen: [AppAppearance] = []
        setting.onChange = { seen.append($0) }
        setting.appearance = .light
        setting.appearance = .light
        setting.appearance = .system
        XCTAssertEqual(seen, [.light, .system])
    }
}
