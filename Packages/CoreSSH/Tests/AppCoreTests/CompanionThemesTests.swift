import XCTest
import CoreModels
@testable import AppCore

/// iPhone/iPad: a short list of built-in themes, picked once in Settings for every session. Host and
/// group themes set on the Mac are not used on iOS.
final class CompanionThemesTests: XCTestCase {
    func testTheChoicesAreAShortListTheCatalogKnows() {
        let ids = CompanionThemes.choices.map(\.id)
        XCTAssertEqual(ids, ["reimagined-dark", "reimagined-light", "dracula", "nord",
                             "solarized-dark", "solarized-light", "everforest-dark", "hacker-green"])
        XCTAssertEqual(CompanionThemes.choices.first?.name, "SwiftSSH Dark")
    }

    func testAChosenThemeAppliesWhateverTheColourScheme() {
        XCTAssertEqual(CompanionThemes.theme(selectedID: "dracula", prefersDark: false).id, "dracula")
        XCTAssertEqual(CompanionThemes.theme(selectedID: "solarized-light", prefersDark: true).id, "solarized-light")
    }

    func testNoChoiceIsAutomatic() {
        XCTAssertEqual(CompanionThemes.theme(selectedID: nil, prefersDark: true).id, "reimagined-dark")
        XCTAssertEqual(CompanionThemes.theme(selectedID: nil, prefersDark: false).id, "reimagined-light")
    }

    func testAThemeOutsideTheListFallsBackToAutomatic() {
        // e.g. a device default chosen before the list was shortened
        XCTAssertEqual(CompanionThemes.theme(selectedID: "kanagawa-wave", prefersDark: true).id, "reimagined-dark")
        XCTAssertEqual(CompanionThemes.theme(selectedID: "no-such-theme", prefersDark: false).id, "reimagined-light")
    }
}
