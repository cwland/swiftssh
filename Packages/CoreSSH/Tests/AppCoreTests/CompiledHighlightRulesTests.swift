import XCTest
import CoreModels
@testable import AppCore

/// The custom-rule matching engine: literal and regex rules, case, whole words, overlaps,
/// disabled and invalid rules, unicode offsets and the slow-regex guards.
final class CompiledHighlightRulesTests: XCTestCase {
    private let red = HighlightPalette.colors[0].color
    private let blue = HighlightPalette.colors[5].color

    private func rule(_ pattern: String, regex: Bool = false, matchCase: Bool = false, color: RGBColor? = nil,
                      bold: Bool = false, enabled: Bool = true) -> HighlightRule {
        HighlightRule(pattern: pattern, isRegularExpression: regex, matchCase: matchCase,
                      color: (color ?? red).hex, isBold: bold, isEnabled: enabled)
    }

    /// The matched substrings, in order.
    private func matched(_ rules: [HighlightRule], in text: String) -> [String] {
        let compiled = CompiledHighlightRules(rules: rules)
        let bytes = Array(text.utf8)
        return compiled.matches(in: text).map { String(decoding: bytes[$0.range], as: UTF8.self) }
    }

    // MARK: Literal rules

    func testLiteralIsCaseInsensitiveByDefault() {
        XCTAssertEqual(matched([rule("prod")], in: "PROD prod Prod"), ["PROD", "prod", "Prod"])
    }

    func testMatchCase() {
        XCTAssertEqual(matched([rule("prod", matchCase: true)], in: "PROD prod Prod"), ["prod"])
    }

    func testLiteralMatchesWholeWordsOnly() {
        XCTAssertEqual(matched([rule("prod")], in: "production prod-db reprod prod_1 prod.example (prod)"),
                       ["prod", "prod", "prod"])
    }

    func testPhraseWithSpaces() {
        XCTAssertEqual(matched([rule("disk full")], in: "warning: Disk Full on /dev/sda1; disk  full"), ["Disk Full"])
    }

    func testLiteralSpecialCharactersAreNotRegex() {
        XCTAssertEqual(matched([rule("a.b")], in: "axb a.b"), ["a.b"])
        XCTAssertEqual(matched([rule("[WARN]")], in: "x[WARN]y [warn] WARN"), ["[WARN]", "[warn]"])
        XCTAssertEqual(matched([rule("(*)")], in: "(*) ()"), ["(*)"])
    }

    func testLiteralEdgeThatIsNotAWordCharacterNeedsNoBoundary() {
        // "#123" starts with #, so "a#123" still matches; it ends with a digit, so "#1234" doesn't.
        XCTAssertEqual(matched([rule("#123")], in: "a#123 #1234 #123"), ["#123", "#123"])
    }

    func testMultipleMatchesPerLine() {
        XCTAssertEqual(matched([rule("ok")], in: "ok, ok; ok!"), ["ok", "ok", "ok"])
    }

    // MARK: Unicode

    func testUnicodeOffsetsAreUTF8() {
        let text = "café → ÉCOLE école 🙂 done"
        let compiled = CompiledHighlightRules(rules: [rule("école"), rule("done")])
        let bytes = Array(text.utf8)
        let found = compiled.matches(in: text).map { String(decoding: bytes[$0.range], as: UTF8.self) }
        XCTAssertEqual(found, ["ÉCOLE", "école", "done"])
    }

    func testUnicodeLettersCountAsWordCharacters() {
        XCTAssertEqual(matched([rule("ok")], in: "éok okä ok"), ["ok"])
    }

    func testEmojiPattern() {
        XCTAssertEqual(matched([rule("🔥")], in: "hot🔥 🔥"), ["🔥", "🔥"])
    }

    // MARK: Regular expressions

    func testRegexMatchesAnywhere() {
        XCTAssertEqual(matched([rule("prod\\d+", regex: true)], in: "xprod12 prod3 prod"), ["prod12", "prod3"])
    }

    func testRegexCaseInsensitiveByDefaultAndMatchCase() {
        XCTAssertEqual(matched([rule("err(or)?", regex: true)], in: "ERR Error"), ["ERR", "Error"])
        XCTAssertEqual(matched([rule("err(or)?", regex: true, matchCase: true)], in: "ERR Error err"), ["err"])
    }

    func testRegexEmptyMatchesAreIgnored() {
        XCTAssertEqual(matched([rule("x*", regex: true)], in: "a xx b x"), ["xx", "x"])
        XCTAssertEqual(matched([rule("^", regex: true)], in: "abc"), [])
    }

    func testInvalidRegexIsSkippedAndReported() {
        let bad = rule("(unclosed", regex: true)
        let good = rule("fine")
        let compiled = CompiledHighlightRules(rules: [bad, good])
        XCTAssertNotNil(compiled.errors[bad.id])
        XCTAssertNil(compiled.errors[good.id])
        XCTAssertEqual(matched([bad, good], in: "(unclosed fine"), ["fine"])
        XCTAssertNotNil(bad.validationError)
        XCTAssertNil(good.validationError)
        XCTAssertNotNil(rule("[a-", regex: true).validationError)
        XCTAssertNotNil(rule("*", regex: true).validationError)
    }

    func testSameTextAsLiteralIsValid() {
        XCTAssertNil(rule("(unclosed").validationError)
        XCTAssertEqual(matched([rule("(unclosed")], in: "x (unclosed"), ["(unclosed"])
    }

    func testEmptyPatternIsAnError() {
        XCTAssertEqual(rule("").validationError, "Enter a word or phrase.")
        XCTAssertEqual(rule("", regex: true).validationError, "Enter a regular expression.")
        XCTAssertTrue(CompiledHighlightRules(rules: [rule("")]).isEmpty)
    }

    // MARK: Enabled, priority, overlaps

    func testDisabledRulesDoNotMatch() {
        XCTAssertEqual(matched([rule("prod", enabled: false), rule("db")], in: "prod db"), ["db"])
        XCTAssertTrue(CompiledHighlightRules(rules: [rule("prod", enabled: false)]).isEmpty)
    }

    func testEarlierRuleWinsOverlaps() {
        let first = rule("prod-db", color: red)
        let second = rule("db-backup", color: blue)
        let compiled = CompiledHighlightRules(rules: [first, second])
        let matches = compiled.matches(in: "prod-db-backup")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range, 0..<7)
        XCTAssertEqual(matches[0].style.color, red)
        XCTAssertEqual(matches[0].ruleIndex, 0)

        let swapped = CompiledHighlightRules(rules: [second, first]).matches(in: "prod-db-backup")
        XCTAssertEqual(swapped.map(\.range), [5..<14])
        XCTAssertEqual(swapped.first?.style.color, blue)
    }

    func testContainedMatchOfLaterRuleIsDropped() {
        XCTAssertEqual(matched([rule("disk full"), rule("full"), rule("now")], in: "disk full now, full"),
                       ["disk full", "now", "full"])
    }

    func testMatchesAreSortedByPosition() {
        let compiled = CompiledHighlightRules(rules: [rule("zeta"), rule("alpha")])
        XCTAssertEqual(compiled.matches(in: "alpha zeta alpha").map(\.range.lowerBound), [0, 6, 11])
    }

    func testStyleCarriesColourAndBold() {
        let compiled = CompiledHighlightRules(rules: [rule("x", color: blue, bold: true)])
        XCTAssertEqual(compiled.matches(in: "x").first?.style, HighlightStyle(color: blue, isBold: true))
    }

    func testUnparsableColourFallsBackToPaletteDefault() {
        var r = rule("x")
        r.color = "not a colour"
        XCTAssertEqual(r.rgbColor, HighlightPalette.defaultColor)
    }

    func testEqualityFollowsRules() {
        let rules = [rule("a"), rule("b")]
        XCTAssertEqual(CompiledHighlightRules(rules: rules), CompiledHighlightRules(rules: rules))
        XCTAssertNotEqual(CompiledHighlightRules(rules: rules), CompiledHighlightRules(rules: [rules[0]]))
    }

    // MARK: Slow regular expressions

    func testRegexSkipsOverlongLinesButLiteralsDoNot() {
        let long = String(repeating: "x", count: CompiledHighlightRules.maxRegexLineLength) + " prod tag"
        XCTAssertEqual(matched([rule("prod", regex: true), rule("tag")], in: long), ["tag"])
        let short = "x prod tag"
        XCTAssertEqual(matched([rule("prod", regex: true), rule("tag")], in: short), ["prod", "tag"])
    }

    func testCatastrophicRegexIsTimeBoxed() {
        // (a+)+$ on "aaaa…b" backtracks exponentially; the time limit must stop it.
        let text = String(repeating: "a", count: 40) + "b done"
        let compiled = CompiledHighlightRules(rules: [rule("(a+)+$", regex: true), rule("done")])
        let start = ContinuousClock.now
        let found = compiled.matches(in: text)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
        XCTAssertEqual(found.count, 1) // the literal rule still matched
    }

    func testSpentBudgetSkipsMatching() {
        let spent = CompiledHighlightRules.MatchBudget(deadline: .now - .seconds(1))
        let compiled = CompiledHighlightRules(rules: [rule("prod", regex: true), rule("tag")])
        XCTAssertEqual(compiled.matches(in: "prod tag", budget: spent), [])
        let fresh = CompiledHighlightRules.MatchBudget.starting(allowance: .seconds(10))
        XCTAssertEqual(compiled.matches(in: "prod tag", budget: fresh).count, 2)
    }

    func testMatchesPerLineAreCapped() {
        let text = Array(repeating: "x", count: 1000).joined(separator: " ")
        XCTAssertEqual(CompiledHighlightRules(rules: [rule("x")]).matches(in: text).count,
                       CompiledHighlightRules.maxMatchesPerLine)
    }

    // MARK: Palette

    func testPaletteReadsOnLightAndDarkBackgrounds() {
        let white = RGBColor(red: 255, green: 255, blue: 255)
        let dark = RGBColor(red: 0x1E, green: 0x1E, blue: 0x1E)
        XCTAssertEqual(HighlightPalette.colors.count, 8)
        XCTAssertEqual(Set(HighlightPalette.colors.map(\.color)).count, 8)
        for entry in HighlightPalette.colors {
            XCTAssertGreaterThanOrEqual(entry.color.contrastRatio(with: white), 3, entry.name)
            XCTAssertGreaterThanOrEqual(entry.color.contrastRatio(with: dark), 3, entry.name)
        }
        XCTAssertEqual(HighlightPalette.entry(for: HighlightPalette.colors[3].color)?.name, "Green")
        XCTAssertNil(HighlightPalette.entry(for: RGBColor(red: 1, green: 2, blue: 3)))
    }
}
