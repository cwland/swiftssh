import XCTest
import CoreModels
@testable import AppCore

/// The custom-rule stream filter, alone and in front of the keyword highlighter (as in a terminal).
final class CustomHighlighterTests: XCTestCase {
    private let red = HighlightPalette.colors[0].color
    private let blue = HighlightPalette.colors[5].color

    private func rule(_ pattern: String, regex: Bool = false, color: RGBColor? = nil, bold: Bool = false,
                      enabled: Bool = true) -> HighlightRule {
        HighlightRule(pattern: pattern, isRegularExpression: regex, color: (color ?? red).hex, isBold: bold,
                      isEnabled: enabled)
    }

    private func open(_ c: RGBColor, bold: Bool = false) -> String {
        "\u{1B}[\(bold ? "1;" : "")38;2;\(c.red);\(c.green);\(c.blue)m"
    }

    private let close = "\u{1B}[39m"
    private let closeBold = "\u{1B}[22;39m"

    private func run(_ chunks: [String], _ rules: [HighlightRule]) -> String {
        let h = CustomHighlighter(rules: CompiledHighlightRules(rules: rules))
        var out: [UInt8] = []
        for chunk in chunks { out += h.process(ArraySlice(Array(chunk.utf8))) }
        return String(decoding: out, as: UTF8.self)
    }

    private func run(_ text: String, _ rules: [HighlightRule]) -> String { run([text], rules) }

    /// Removes every colour code this filter inserts.
    private func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[(1;)?38;2;\\d+;\\d+;\\d+m|\u{1B}\\[(22;)?39m", with: "",
                               options: .regularExpression)
    }

    func testWrapsMatches() {
        XCTAssertEqual(run("deploy to prod now\r\n", [rule("prod")]), "deploy to \(open(red))prod\(close) now\r\n")
    }

    func testNoRulesIsByteIdentical() {
        let text = "\u{1B}[31mred\u{1B}[0m prod \u{1B}]0;title\u{07}"
        XCTAssertEqual(run(text, []), text)
        XCTAssertEqual(run(text, [rule("prod", enabled: false)]), text)
    }

    func testMultipleRulesAndMatchesOnALine() {
        XCTAssertEqual(run("prod db prod\r\n", [rule("prod"), rule("db", color: blue)]),
                       "\(open(red))prod\(close) \(open(blue))db\(close) \(open(red))prod\(close)\r\n")
    }

    func testBold() {
        XCTAssertEqual(run("a prod\r\n", [rule("prod", bold: true)]), "a \(open(red, bold: true))prod\(closeBold)\r\n")
    }

    func testBoldNotAddedWhereTextIsAlreadyBoldOrFaint() {
        XCTAssertEqual(run("\u{1B}[1mprod\u{1B}[0m", [rule("prod", bold: true)]),
                       "\u{1B}[1m\(open(red))prod\(close)\u{1B}[0m")
        XCTAssertEqual(run("\u{1B}[2mprod\u{1B}[22m prod ", [rule("prod", bold: true)]),
                       "\u{1B}[2m\(open(red))prod\(close)\u{1B}[22m \(open(red, bold: true))prod\(closeBold) ")
    }

    func testProgramColoursAreNotOverridden() {
        let text = "\u{1B}[32mprod\u{1B}[39m prod\r\n"
        XCTAssertEqual(run(text, [rule("prod")]), "\u{1B}[32mprod\u{1B}[39m \(open(red))prod\(close)\r\n")
        let inverse = "\u{1B}[7mprod\u{1B}[27m"
        XCTAssertEqual(run(inverse, [rule("prod")]), inverse)
    }

    func testOffOnTheAlternateScreen() {
        let text = "\u{1B}[?1049hprod\u{1B}[?1049lprod\r\n"
        XCTAssertEqual(run(text, [rule("prod")]), "\u{1B}[?1049hprod\u{1B}[?1049l\(open(red))prod\(close)\r\n")
    }

    func testNeverInsertsInsideEscapeSequences() {
        // "prod" inside an OSC title and a DCS string are not text.
        let text = "\u{1B}]0;prod\u{07}\u{1B}Pprod\u{1B}\\x"
        XCTAssertEqual(run(text, [rule("prod")]), text)
    }

    func testMatchDoesNotSpanEscapesOrLineBreaks() {
        let text = "disk\u{1B}[0m full disk\r\nfull"
        XCTAssertEqual(run(text, [rule("disk full")]), text)
    }

    func testTabIsPartOfARun() {
        XCTAssertEqual(run("a\tb\r\n", [rule("a\tb")]), "\(open(red))a\tb\(close)\r\n")
    }

    func testChunkBoundaryMissesButNeverHolds() {
        let rules = [rule("prod")]
        let h = CustomHighlighter(rules: CompiledHighlightRules(rules: rules))
        XCTAssertEqual(String(decoding: h.process(ArraySlice(Array("pr".utf8))), as: UTF8.self), "pr")
        XCTAssertEqual(String(decoding: h.process(ArraySlice(Array("od prod\r\n".utf8))), as: UTF8.self),
                       "od \(open(red))prod\(close)\r\n")
    }

    // A word touching a chunk edge may go on in the other chunk: a missed highlight, never a wrong one.

    private func chunks(_ parts: [String], _ rules: [HighlightRule]) -> [String] {
        let h = CustomHighlighter(rules: CompiledHighlightRules(rules: rules))
        return parts.map { String(decoding: h.process(ArraySlice(Array($0.utf8))), as: UTF8.self) }
    }

    func testWordAtTheEndOfAChunkIsNotHighlighted() {
        // "production" split as "prod" | "uction": "prod" must not be coloured inside it.
        XCTAssertEqual(chunks(["deploy prod", "uction\r\n"], [rule("prod")]), ["deploy prod", "uction\r\n"])
        // A phrase whose last character isn't a word character has no guard there: still coloured.
        XCTAssertEqual(chunks(["a prod:"], [rule("prod:")]), ["a \(open(red))prod:\(close)"])
    }

    func testWordAtTheStartOfAChunkAfterAWordIsNotHighlighted() {
        // A rule "uction" must not match the tail of "production" split as "prod" | "uction".
        XCTAssertEqual(chunks(["prod", "uction now\r\n"], [rule("uction")]), ["prod", "uction now\r\n"])
        // After a space, a line break or an escape sequence the start is a real word start.
        XCTAssertEqual(chunks(["go ", "prod now\r\n"], [rule("prod")]), ["go ", "\(open(red))prod\(close) now\r\n"])
        XCTAssertEqual(chunks(["x\r\n", "prod now\r\n"], [rule("prod")]),
                       ["x\r\n", "\(open(red))prod\(close) now\r\n"])
        XCTAssertEqual(chunks(["x\u{1B}[0m", "prod now\r\n"], [rule("prod")]),
                       ["x\u{1B}[0m", "\(open(red))prod\(close) now\r\n"])
        // After a cut non-ASCII character (could be a letter), too.
        let e = Array("é".utf8)
        let h = CustomHighlighter(rules: CompiledHighlightRules(rules: [rule("prod")]))
        _ = h.process(ArraySlice([e[0]]))
        XCTAssertEqual(h.process(ArraySlice([e[1]] + Array("prod now\r\n".utf8))), [e[1]] + Array("prod now\r\n".utf8))
    }

    func testRegexRulesAreNotAffectedByChunkEdges() {
        XCTAssertEqual(chunks(["deploy prod"], [rule("prod", regex: true)]), ["deploy \(open(red))prod\(close)"])
    }

    func testEdgeMatchStaysPlainRatherThanGoingToALaterRule() {
        XCTAssertEqual(chunks(["a prod"], [rule("prod"), rule("prod", regex: true, color: blue)]), ["a prod"])
    }

    // MARK: Floods

    func testLargeChunksInQuickSuccessionPassThroughPlain() {
        var clock = ContinuousClock.now
        let h = CustomHighlighter(rules: CompiledHighlightRules(rules: [rule("prod")]), now: { clock })
        let big = String(repeating: "prod ok\r\n", count: 2_000) // 18 KB
        let small = "prod ok\r\n"
        let coloured = "\(open(red))prod\(close) ok\r\n"
        func feed(_ text: String) -> String { String(decoding: h.process(ArraySlice(Array(text.utf8))), as: UTF8.self) }

        XCTAssertTrue(feed(big).hasPrefix(coloured), "the first big chunk isn't a flood yet")
        clock += .milliseconds(2)
        XCTAssertEqual(feed(big), big, "a big chunk right after another: plain")
        clock += .milliseconds(2)
        XCTAssertEqual(feed(small), coloured, "small chunks are always matched")
        clock += .milliseconds(50)
        XCTAssertTrue(feed(big).hasPrefix(coloured), "output slowed down: matched again")
        clock += .milliseconds(9)
        XCTAssertEqual(feed(big), big)
    }

    func testFloodSkipKeepsTrackingTheTerminalState() {
        var clock = ContinuousClock.now
        let h = CustomHighlighter(rules: CompiledHighlightRules(rules: [rule("prod")]), now: { clock })
        _ = h.process(ArraySlice(Array("x\r\n".utf8)))
        clock += .milliseconds(1)
        // A flood chunk that switches to the alternate screen (vim) at its end.
        let flood = Array(String(repeating: "prod ok\r\n", count: 2_000).utf8) + Array("\u{1B}[?1049h".utf8)
        XCTAssertEqual(h.process(ArraySlice(flood)), flood)
        clock += .seconds(1)
        XCTAssertEqual(String(decoding: h.process(ArraySlice(Array("prod\r\n".utf8))), as: UTF8.self), "prod\r\n",
                       "still knows it is on the alternate screen")
    }

    func testEveryByteIsKeptForAllSplits() {
        let text = "été prod 🙂 \u{1B}[31mprod\u{1B}[0m x prod-db\r\n"
        let bytes = Array(text.utf8)
        let rules = CompiledHighlightRules(rules: [rule("prod"), rule("🙂"), rule("été", regex: true)])
        for cut in 0...bytes.count {
            let h = CustomHighlighter(rules: rules)
            var out = h.process(bytes[0..<cut])
            out += h.process(bytes[cut...])
            XCTAssertEqual(Array(strip(String(decoding: out, as: UTF8.self)).utf8), bytes, "split at \(cut)")
            // Inserted codes only at character boundaries: the output is valid UTF-8.
            XCTAssertNotNil(String(bytes: out, encoding: .utf8), "split at \(cut)")
        }
    }

    func testUnicodeMatches() {
        XCTAssertEqual(run("Ünïcödé ÉCOLE école\r\n", [rule("école")]),
                       "Ünïcödé \(open(red))ÉCOLE\(close) \(open(red))école\(close)\r\n")
    }

    func testInvalidUTF8RunIsPassedThrough() {
        let bytes: [UInt8] = Array("prod ".utf8) + [0xFF] + Array(" prod".utf8)
        let h = CustomHighlighter(rules: CompiledHighlightRules(rules: [rule("prod")]))
        XCTAssertEqual(h.process(bytes[...]), bytes)
    }

    func testInvalidRegexNeverCrashes() {
        XCTAssertEqual(run("(x prod\r\n", [rule("(x", regex: true), rule("prod")]), "(x \(open(red))prod\(close)\r\n")
    }

    func testUpdateAppliesLive() {
        let h = CustomHighlighter()
        XCTAssertEqual(String(decoding: h.process(ArraySlice(Array("prod ".utf8))), as: UTF8.self), "prod ")
        h.update(rules: CompiledHighlightRules(rules: [rule("prod")]))
        XCTAssertEqual(String(decoding: h.process(ArraySlice(Array("prod\r\n".utf8))), as: UTF8.self),
                       "\(open(red))prod\(close)\r\n")
    }

    func testStateIsTrackedWhileThereAreNoRules() {
        let h = CustomHighlighter()
        _ = h.process(ArraySlice(Array("\u{1B}[31m".utf8)))
        h.update(rules: CompiledHighlightRules(rules: [rule("prod")]))
        XCTAssertEqual(String(decoding: h.process(ArraySlice(Array("prod".utf8))), as: UTF8.self), "prod")
    }

    func testFloodOfOutputIsBoundedAndKeepsEveryByte() {
        let line = "2026-11-15 INFO prod-12 handled request in 12ms word3\r\n"
        let text = String(repeating: line, count: 4000) // ~220 KB in one chunk
        let rules = (0..<8).map { rule("word\($0)") } + [rule("prod-\\d+", regex: true)]
        let h = CustomHighlighter(rules: CompiledHighlightRules(rules: rules))
        let start = ContinuousClock.now
        let out = h.process(ArraySlice(Array(text.utf8)))
        // The budget, plus the line in progress and generous slack for a slow test machine.
        XCTAssertLessThan(ContinuousClock.now - start, CustomHighlighter.matchBudgetPerChunk + .milliseconds(500))
        XCTAssertEqual(strip(String(decoding: out, as: UTF8.self)), text)
        XCTAssertTrue(String(decoding: out, as: UTF8.self).hasPrefix("2026-11-15 INFO \(open(red))prod-12\(close)"))
    }

    // MARK: Together with the built-in keywords

    private func pipeline(_ text: String, _ rules: [HighlightRule]) -> String {
        let custom = CustomHighlighter(rules: CompiledHighlightRules(rules: rules))
        let keywords = KeywordHighlighter(settings: .default)
        return String(decoding: keywords.process(custom.process(ArraySlice(Array(text.utf8)))[...]), as: UTF8.self)
    }

    private func keyword(_ text: String, _ category: KeywordCategory) -> String {
        let c = category.defaultColor
        return "\u{1B}[38;2;\(c.red);\(c.green);\(c.blue)m\(text)\(close)"
    }

    func testCustomRulesWinOverBuiltInKeywords() {
        XCTAssertEqual(pipeline("error on prod: error\r\n", [rule("on prod: error")]),
                       "\(keyword("error", .error)) \(open(red))on prod: error\(close)\r\n")
        XCTAssertEqual(pipeline("failed ok\r\n", [rule("failed", color: blue)]),
                       "\(open(blue))failed\(close) \(keyword("ok", .ok))\r\n")
    }

    func testBuiltInsStillApplyBesideCustomRules() {
        XCTAssertEqual(pipeline("warning prod 10.0.0.1\r\n", [rule("prod")]),
                       "\(keyword("warning", .warning)) \(open(red))prod\(close) \(keyword("10.0.0.1", .network))\r\n")
    }

    func testKeywordHighlighterKeepsBracketedPasteTrackingThroughCustomCodes() {
        let custom = CustomHighlighter(rules: CompiledHighlightRules(rules: [rule("prod")]))
        let keywords = KeywordHighlighter(settings: .default)
        _ = keywords.process(custom.process(ArraySlice(Array("\u{1B}[?2004hprod".utf8)))[...])
        XCTAssertTrue(keywords.isBracketedPasteActive)
    }
}
