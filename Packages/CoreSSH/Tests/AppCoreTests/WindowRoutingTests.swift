import XCTest
@testable import AppCore

final class WindowRoutingTests: XCTestCase {
    // MARK: Cmd+W

    func testCloseClosesTheTabOrPaneWhenAnAppWindowIsKey() {
        XCTAssertEqual(WindowRouting.closeCommand(keyWindow: .appWindow, hasActiveTab: true), .closeTabOrPane)
    }

    func testCloseClosesAnAppWindowShowingVaults() {
        XCTAssertEqual(WindowRouting.closeCommand(keyWindow: .appWindow, hasActiveTab: false), .closeKeyWindow)
    }

    func testCloseClosesSettingsOrAnyOtherWindowEvenWithATabSelected() {
        XCTAssertEqual(WindowRouting.closeCommand(keyWindow: .otherWindow, hasActiveTab: true), .closeKeyWindow)
        XCTAssertEqual(WindowRouting.closeCommand(keyWindow: .otherWindow, hasActiveTab: false), .closeKeyWindow)
    }

    func testCloseWithNoKeyWindowStillClosesTheTab() {
        XCTAssertEqual(WindowRouting.closeCommand(keyWindow: nil, hasActiveTab: true), .closeTabOrPane)
        XCTAssertEqual(WindowRouting.closeCommand(keyWindow: nil, hasActiveTab: false), .closeKeyWindow)
    }

    // MARK: Which window shows a prompt

    func testThePromptGoesToTheKeyWindowWhenItShowsTheWorkspace() {
        XCTAssertEqual(WindowRouting.promptWindow(among: [1, 2, 3], keyWindow: 2), 2)
    }

    func testOtherwiseToTheFrontmostWindowShowingIt() {
        XCTAssertEqual(WindowRouting.promptWindow(among: [3, 1], keyWindow: 9), 3)
    }

    func testWithNoWindowShowingItTheKeyWindowIsUsed() {
        XCTAssertEqual(WindowRouting.promptWindow(among: [Int](), keyWindow: 9), 9)
        XCTAssertNil(WindowRouting.promptWindow(among: [Int](), keyWindow: nil))
    }

    func testARequestIsTakenOnlyByItsWindow() {
        let pane = UUID()
        let request = WindowTargetedRequest(subjectID: pane, window: 1)
        XCTAssertTrue(request.isFor(window: 1))
        XCTAssertFalse(request.isFor(window: 2), "a second main window showing the same workspace doesn't ask")
        XCTAssertFalse(request.isFor(window: nil))
        let untargeted = WindowTargetedRequest<Int>(subjectID: pane, window: nil)
        XCTAssertFalse(untargeted.isFor(window: 1), "no window identified: nobody asks (the pane closes after the timeout)")
        XCTAssertFalse(untargeted.isFor(window: nil))
    }

    func testRequestsForTheSameSubjectInDifferentWindowsDiffer() {
        let pane = UUID()
        XCTAssertNotEqual(WindowTargetedRequest(subjectID: pane, window: 1), WindowTargetedRequest(subjectID: pane, window: 2))
    }
}
