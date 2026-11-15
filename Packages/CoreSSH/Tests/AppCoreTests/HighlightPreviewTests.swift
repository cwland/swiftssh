import XCTest
import CoreModels
@testable import AppCore

final class HighlightPreviewTests: XCTestCase {
    private let red = HighlightPalette.colors[0].color

    func testPlainText() {
        XCTAssertEqual(HighlightPreview.segments(for: "hello there", keywords: .default, rules: .empty),
                       [.init(text: "hello there")])
    }

    func testCustomRulesAndKeywordsTogether() {
        let rules = CompiledHighlightRules(rules: [HighlightRule(pattern: "prod", color: red.hex, isBold: true)])
        let segments = HighlightPreview.segments(for: "error on prod now", keywords: .default, rules: rules)
        XCTAssertEqual(segments, [
            .init(text: "error", color: KeywordCategory.error.defaultColor),
            .init(text: " on "),
            .init(text: "prod", color: red, isBold: true),
            .init(text: " now"),
        ])
    }

    func testKeywordAtTheEndIsColoured() {
        XCTAssertEqual(HighlightPreview.segments(for: "all ok", keywords: .default, rules: .empty),
                       [.init(text: "all "), .init(text: "ok", color: KeywordCategory.ok.defaultColor)])
    }

    func testKeywordsOffShowsOnlyCustomRules() {
        let rules = CompiledHighlightRules(rules: [HighlightRule(pattern: "prod", color: red.hex)])
        let segments = HighlightPreview.segments(for: "error prod", keywords: .init(isEnabled: false), rules: rules)
        XCTAssertEqual(segments, [.init(text: "error "), .init(text: "prod", color: red)])
    }

    func testControlCharactersBecomeSpacesAndUnicodeSurvives() {
        let rules = CompiledHighlightRules(rules: [HighlightRule(pattern: "école", color: red.hex)])
        let segments = HighlightPreview.segments(for: "a\u{1B}b\nÉcole 🙂", keywords: .init(isEnabled: false), rules: rules)
        XCTAssertEqual(segments, [.init(text: "a b "), .init(text: "École", color: red), .init(text: " 🙂")])
    }
}
