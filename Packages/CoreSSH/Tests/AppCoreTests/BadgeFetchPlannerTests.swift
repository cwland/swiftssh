import XCTest
import CoreModels
@testable import AppCore

final class BadgeFetchPlannerTests: XCTestCase {
    private func candidate(_ badge: OSBadge, defaultLink: String = "https://x/\u{0}.svg", custom: String? = nil,
                           hasLogo: Bool = false, source: String? = nil, owns: Bool = false) -> BadgeFetchCandidate {
        BadgeFetchCandidate(badge: badge, defaultLink: defaultLink, customLink: custom,
                            hasLogo: hasLogo, imageSource: source, ownsDownloadedImage: owns)
    }

    func testFirstRunFetchesEverythingWithALink() {
        let plan = BadgeFetchPlanner.plan([
            candidate(.ubuntu, defaultLink: "https://a/u.svg"),
            candidate(.debian, defaultLink: "https://a/d.svg", hasLogo: true, source: "https://a/d.svg", owns: true),
            candidate(.fedora, defaultLink: ""),
        ], isFirstRun: true)
        XCTAssertEqual(plan.map(\.badge), [.ubuntu, .debian])
        XCTAssertEqual(plan.map(\.link), ["https://a/u.svg", "https://a/d.svg"])
    }

    func testFirstRunNeverReplacesAUserSuppliedImage() {
        let plan = BadgeFetchPlanner.plan([
            candidate(.ubuntu, defaultLink: "https://a/u.svg", hasLogo: true, source: nil, owns: false),
            candidate(.debian, defaultLink: "https://a/d.svg", hasLogo: true, source: "https://a/d.svg", owns: false),
        ], isFirstRun: true)
        XCTAssertTrue(plan.isEmpty)
    }

    func testLaterLaunchFetchesOnlyMissing() {
        let plan = BadgeFetchPlanner.plan([
            candidate(.ubuntu, defaultLink: "https://a/u.svg", hasLogo: true, source: "https://a/u.svg", owns: true),
            candidate(.debian, defaultLink: "https://a/d.svg"),
        ], isFirstRun: false)
        XCTAssertEqual(plan.map(\.badge), [.debian])
    }

    func testLaterLaunchRefetchesWhenTheLinkChanged() {
        let plan = BadgeFetchPlanner.plan([
            candidate(.ubuntu, defaultLink: "https://a/new.svg", hasLogo: true, source: "https://a/old.svg", owns: true),
            candidate(.debian, defaultLink: "https://a/d.svg", custom: "https://b/d.png",
                      hasLogo: true, source: "https://a/d.svg", owns: true),
        ], isFirstRun: false)
        XCTAssertEqual(plan.map(\.badge), [.ubuntu, .debian])
        XCTAssertEqual(plan.map(\.link), ["https://a/new.svg", "https://b/d.png"])
    }

    func testLaterLaunchKeepsUserSuppliedImagesEvenWithAStaleLink() {
        let plan = BadgeFetchPlanner.plan([
            candidate(.ubuntu, defaultLink: "https://a/new.svg", hasLogo: true, source: "https://a/old.svg", owns: false),
            candidate(.debian, defaultLink: "https://a/d.svg", hasLogo: true, source: nil, owns: false),
        ], isFirstRun: false)
        XCTAssertTrue(plan.isEmpty)
    }

    func testFailedDownloadsAreMissingSoTheyAreRetried() {
        // A failed download leaves no image and no source, so the next launch sees it as missing.
        let plan = BadgeFetchPlanner.plan([candidate(.ubuntu, defaultLink: "https://a/u.svg")], isFirstRun: false)
        XCTAssertEqual(plan.map(\.badge), [.ubuntu])
    }

    func testCustomLinkWithoutImageIsFetchedFromTheCustomLink() {
        let plan = BadgeFetchPlanner.plan([candidate(.ubuntu, defaultLink: "https://a/u.svg", custom: "https://b/u.png")],
                                          isFirstRun: false)
        XCTAssertEqual(plan.map(\.link), ["https://b/u.png"])
    }

    func testNoLinkMeansNothingToFetch() {
        XCTAssertTrue(BadgeFetchPlanner.plan([candidate(.ubuntu, defaultLink: "")], isFirstRun: true).isEmpty)
    }
}
