import XCTest
@testable import AppCore

final class PaneTreeTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    // MARK: paneIDs

    func testPaneIDsAreInReadingOrder() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a),
                                  .split(.vertical, ratio: 0.5, .pane(b), .pane(c)))
        XCTAssertEqual(tree.paneIDs, [a, b, c])
        XCTAssertEqual(PaneNode.pane(a).paneIDs, [a])
    }

    // MARK: inserting

    func testInsertingOnEachEdge() {
        XCTAssertEqual(PaneNode.pane(a).inserting(b, beside: a, at: .left),
                       .split(.horizontal, ratio: 0.5, .pane(b), .pane(a)))
        XCTAssertEqual(PaneNode.pane(a).inserting(b, beside: a, at: .right),
                       .split(.horizontal, ratio: 0.5, .pane(a), .pane(b)))
        XCTAssertEqual(PaneNode.pane(a).inserting(b, beside: a, at: .top),
                       .split(.vertical, ratio: 0.5, .pane(b), .pane(a)))
        XCTAssertEqual(PaneNode.pane(a).inserting(b, beside: a, at: .bottom),
                       .split(.vertical, ratio: 0.5, .pane(a), .pane(b)))
    }

    func testInsertingSplitsOnlyTheTargetAndKeepsOtherRatios() {
        let tree = PaneNode.split(.horizontal, ratio: 0.3, .pane(a), .pane(b))
        XCTAssertEqual(tree.inserting(c, beside: b, at: .bottom),
                       .split(.horizontal, ratio: 0.3, .pane(a), .split(.vertical, ratio: 0.5, .pane(b), .pane(c))))
    }

    func testInsertingBesideAnUnknownTargetChangesNothing() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .pane(b))
        XCTAssertEqual(tree.inserting(c, beside: d, at: .left), tree)
    }

    func testInsertingAnIDAlreadyThereMovesIt() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .split(.vertical, ratio: 0.5, .pane(b), .pane(c)))
        let result = tree.inserting(a, beside: c, at: .right)
        XCTAssertEqual(result, .split(.vertical, ratio: 0.5, .pane(b), .split(.horizontal, ratio: 0.5, .pane(c), .pane(a))))
    }

    func testInsertingBesideItselfChangesNothing() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .pane(b))
        XCTAssertEqual(tree.inserting(a, beside: a, at: .left), tree)
    }

    // MARK: removing

    func testRemovingTheOnlyPaneLeavesNothing() {
        XCTAssertNil(PaneNode.pane(a).removing(a))
    }

    func testRemovingCollapsesTheSplit() {
        let tree = PaneNode.split(.horizontal, ratio: 0.3, .pane(a),
                                  .split(.vertical, ratio: 0.7, .pane(b), .pane(c)))
        XCTAssertEqual(tree.removing(b), .split(.horizontal, ratio: 0.3, .pane(a), .pane(c)))
        XCTAssertEqual(tree.removing(a), .split(.vertical, ratio: 0.7, .pane(b), .pane(c)))
    }

    func testRemovingAnUnknownIDChangesNothing() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .pane(b))
        XCTAssertEqual(tree.removing(c), tree)
        XCTAssertEqual(PaneNode.pane(a).removing(b), .pane(a))
    }

    // MARK: moving

    func testMovingAPaneBesideAnother() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .split(.vertical, ratio: 0.5, .pane(b), .pane(c)))
        XCTAssertEqual(tree.moving(c, beside: a, at: .top),
                       .split(.horizontal, ratio: 0.5, .split(.vertical, ratio: 0.5, .pane(c), .pane(a)), .pane(b)))
    }

    func testMovingWithinTwoPanesSwapsSides() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .pane(b))
        XCTAssertEqual(tree.moving(a, beside: b, at: .right), .split(.horizontal, ratio: 0.5, .pane(b), .pane(a)))
        XCTAssertEqual(tree.moving(a, beside: b, at: .bottom), .split(.vertical, ratio: 0.5, .pane(b), .pane(a)))
    }

    func testMovingOntoItselfOrUnknownChangesNothing() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .pane(b))
        XCTAssertEqual(tree.moving(a, beside: a, at: .left), tree)
        XCTAssertEqual(tree.moving(c, beside: a, at: .left), tree)
        XCTAssertEqual(tree.moving(a, beside: c, at: .left), tree)
    }

    // MARK: ratios

    func testSettingRatioAtPaths() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a),
                                  .split(.vertical, ratio: 0.5, .pane(b), .pane(c)))
        XCTAssertEqual(tree.settingRatio(0.25, atPath: []),
                       .split(.horizontal, ratio: 0.25, .pane(a), .split(.vertical, ratio: 0.5, .pane(b), .pane(c))))
        XCTAssertEqual(tree.settingRatio(0.75, atPath: [1]),
                       .split(.horizontal, ratio: 0.5, .pane(a), .split(.vertical, ratio: 0.75, .pane(b), .pane(c))))
    }

    func testSettingRatioClamps() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .pane(b))
        XCTAssertEqual(tree.settingRatio(0.01, atPath: []), .split(.horizontal, ratio: 0.1, .pane(a), .pane(b)))
        XCTAssertEqual(tree.settingRatio(5, atPath: []), .split(.horizontal, ratio: 0.9, .pane(a), .pane(b)))
        XCTAssertEqual(tree.settingRatio(.nan, atPath: []), tree)
    }

    func testSettingRatioAtABadPathChangesNothing() {
        let tree = PaneNode.split(.horizontal, ratio: 0.5, .pane(a), .pane(b))
        XCTAssertEqual(tree.settingRatio(0.3, atPath: [0]), tree) // a pane, not a split
        XCTAssertEqual(tree.settingRatio(0.3, atPath: [2]), tree)
        XCTAssertEqual(tree.settingRatio(0.3, atPath: [1, 0]), tree)
        XCTAssertEqual(PaneNode.pane(a).settingRatio(0.3, atPath: []), .pane(a))
    }

    // MARK: Balanced layout and reordering

    func testBalancedLayoutOfTwoIsSideBySide() {
        XCTAssertEqual(PaneNode.balanced([a, b]), .split(.horizontal, ratio: 0.5, .pane(a), .pane(b)))
        XCTAssertEqual(PaneNode.balanced([a]), .pane(a))
        XCTAssertNil(PaneNode.balanced([]))
    }

    func testBalancedLayoutOfFourIsAGrid() {
        XCTAssertEqual(PaneNode.balanced([a, b, c, d]),
                       .split(.vertical, ratio: 0.5,
                              .split(.horizontal, ratio: 0.5, .pane(a), .pane(b)),
                              .split(.horizontal, ratio: 0.5, .pane(c), .pane(d))))
    }

    func testBalancedLayoutOfThreeHasTwoRows() {
        XCTAssertEqual(PaneNode.balanced([a, b, c]),
                       .split(.vertical, ratio: 0.5, .split(.horizontal, ratio: 0.5, .pane(a), .pane(b)), .pane(c)))
    }

    func testBalancedLayoutKeepsReadingOrderAndEqualShares() {
        let ids = (0..<16).map { _ in UUID() }
        let tree = PaneNode.balanced(ids)!
        XCTAssertEqual(tree.paneIDs, ids)
        let six = (0..<6).map { _ in UUID() }
        // 3 columns × 2 rows: the first column takes a third of each row.
        guard case .split(.vertical, 0.5, let row, _) = PaneNode.balanced(six)!,
              case .split(.horizontal, let ratio, _, _) = row else { return XCTFail("shape") }
        XCTAssertEqual(ratio, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testReorderedKeepsTheShapeAndPlacesIDsInReadingOrder() {
        let tree = PaneNode.split(.horizontal, ratio: 0.3, .pane(a), .split(.vertical, ratio: 0.6, .pane(b), .pane(c)))
        XCTAssertEqual(tree.reordered([c, a, b]),
                       .split(.horizontal, ratio: 0.3, .pane(c), .split(.vertical, ratio: 0.6, .pane(a), .pane(b))))
        // Not a permutation of the panes: unchanged.
        XCTAssertEqual(tree.reordered([a, b]), tree)
        XCTAssertEqual(tree.reordered([a, b, d]), tree)
    }

    // MARK: swapping

    func testSwappingTradesTwoPanesPlacesAndKeepsShapeAndRatios() {
        let tree = PaneNode.split(.horizontal, ratio: 0.3, .pane(a), .split(.vertical, ratio: 0.6, .pane(b), .pane(c)))
        XCTAssertEqual(tree.swapping(a, c),
                       .split(.horizontal, ratio: 0.3, .pane(c), .split(.vertical, ratio: 0.6, .pane(b), .pane(a))))
        XCTAssertEqual(tree.swapping(c, a), tree.swapping(a, c))
    }

    func testSwappingWithItselfOrAnUnknownPaneChangesNothing() {
        let tree = PaneNode.split(.horizontal, ratio: 0.3, .pane(a), .pane(b))
        XCTAssertEqual(tree.swapping(a, a), tree)
        XCTAssertEqual(tree.swapping(a, d), tree)
        XCTAssertEqual(tree.swapping(d, b), tree)
    }
}
