import XCTest
@testable import AppCore

/// KeywordHighlighter is a plain (nonisolated, non-Sendable) stream processor, so these tests run
/// off the main actor on purpose.
final class KeywordHighlighterTests: XCTestCase {
    // MARK: - Helpers

    private static let esc = "\u{1B}"
    private static let reset = "\u{1B}[39m"

    private func open(_ category: KeywordCategory, _ colors: [KeywordCategory: RGBColor] = [:]) -> String {
        let c = colors[category] ?? category.defaultColor
        return "\u{1B}[38;2;\(c.red);\(c.green);\(c.blue)m"
    }

    private func wrap(_ text: String, _ category: KeywordCategory) -> String {
        open(category) + text + Self.reset
    }

    /// Feeds `chunks` one by one, then flushes; returns the concatenated output.
    private func run(_ chunks: [String], settings: KeywordHighlightSettings.Snapshot = .default) -> String {
        let highlighter = KeywordHighlighter(settings: settings)
        var out: [UInt8] = []
        for chunk in chunks { out += highlighter.process(ArraySlice(Array(chunk.utf8))) }
        out += highlighter.flush()
        return String(decoding: out, as: UTF8.self)
    }

    private func run(_ text: String) -> String { run([text]) }

    /// Every way of splitting `text` into two chunks: the output, with our inserted colour codes removed, is the
    /// input byte for byte; it equals `expected` with zero or more highlights dropped (a word cut by the chunk
    /// boundary is emitted plain, never held); unsplit (cut at 0 or the end) it equals `expected` exactly.
    private func assertAllSplits(_ text: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let bytes = Array(text.utf8)
        let expectedBytes = Array(expected.utf8)
        for cut in 0...bytes.count {
            let highlighter = KeywordHighlighter(settings: .default)
            var out = highlighter.process(bytes[0..<cut])
            out += highlighter.process(bytes[cut...])
            out += highlighter.flush()
            XCTAssertEqual(stripInserted(out), bytes, "bytes changed, split at \(cut)", file: file, line: line)
            XCTAssertTrue(isExpectedWithSomeHighlightsDropped(out, expectedBytes),
                          "split at \(cut): \(String(decoding: out, as: UTF8.self).debugDescription)", file: file, line: line)
            if cut == 0 || cut == bytes.count {
                XCTAssertEqual(String(decoding: out, as: UTF8.self), expected, "split at \(cut)", file: file, line: line)
            }
        }
    }

    private var insertedOpens: [[UInt8]] { KeywordCategory.allCases.map { Array(open($0).utf8) } }

    private func starts(_ a: [UInt8], at i: Int, with b: [UInt8]) -> Bool {
        i + b.count <= a.count && Array(a[i..<(i + b.count)]) == b
    }

    /// Removes every `open … close` wrapper this highlighter inserts (default colours).
    private func stripInserted(_ out: [UInt8]) -> [UInt8] {
        let close = Array(Self.reset.utf8)
        var result: [UInt8] = []
        var i = 0
        var inMatch = false
        while i < out.count {
            if !inMatch, let o = insertedOpens.first(where: { starts(out, at: i, with: $0) }) {
                i += o.count; inMatch = true; continue
            }
            if inMatch, starts(out, at: i, with: close) { i += close.count; inMatch = false; continue }
            result.append(out[i]); i += 1
        }
        return result
    }

    private func isExpectedWithSomeHighlightsDropped(_ out: [UInt8], _ expected: [UInt8]) -> Bool {
        let close = Array(Self.reset.utf8)
        var i = 0, j = 0
        while j < expected.count {
            if let o = insertedOpens.first(where: { starts(expected, at: j, with: $0) }) {
                var k = j + o.count
                while k < expected.count, !starts(expected, at: k, with: close) { k += 1 }
                let word = Array(expected[(j + o.count)..<k])
                if starts(out, at: i, with: o + word + close) {
                    i += o.count + word.count + close.count
                } else if starts(out, at: i, with: word) {
                    i += word.count
                } else { return false }
                j = k + close.count
                continue
            }
            guard i < out.count, out[i] == expected[j] else { return false }
            i += 1; j += 1
        }
        return i == out.count
    }

    // MARK: - Plain words

    func testHighlightsEachCategory() {
        XCTAssertEqual(run("an error here\n"), "an \(wrap("error", .error)) here\n")
        XCTAssertEqual(run("warning: x\n"), "\(wrap("warning", .warning)): x\n")
        XCTAssertEqual(run("status ok\n"), "status \(wrap("ok", .ok))\n")
        XCTAssertEqual(run("info msg\n"), "\(wrap("info", .info)) msg\n")
        XCTAssertEqual(run("debug msg\n"), "\(wrap("debug", .debug)) msg\n")
        XCTAssertEqual(run("host 10.0.0.1 up\n"), "host \(wrap("10.0.0.1", .network)) \(wrap("up", .ok))\n")
    }

    func testAllListedKeywordsMatch() {
        for category in KeywordCategory.allCases {
            for word in category.keywords {
                XCTAssertEqual(run("x \(word) y\n"), "x \(wrap(word, category)) y\n", word)
            }
        }
    }

    func testKeywordLists() {
        XCTAssertEqual(KeywordCategory.error.keywords, ["error", "errors", "err", "fail", "failed", "failure", "fatal",
                                                       "critical", "denied", "refused", "exception", "panic"])
        XCTAssertEqual(KeywordCategory.warning.keywords, ["warn", "warning", "warnings", "deprecated", "caution"])
        XCTAssertEqual(KeywordCategory.ok.keywords, ["ok", "success", "successful", "succeeded", "done", "passed",
                                                    "active", "running", "enabled", "up"])
        XCTAssertEqual(KeywordCategory.info.keywords, ["info", "notice", "note"])
        XCTAssertEqual(KeywordCategory.debug.keywords, ["debug", "trace", "verbose"])
        XCTAssertEqual(KeywordCategory.network.keywords, [])
    }

    func testCaseInsensitive() {
        XCTAssertEqual(run("ERROR Error eRRoR\n"),
                       "\(wrap("ERROR", .error)) \(wrap("Error", .error)) \(wrap("eRRoR", .error))\n")
        XCTAssertEqual(run("[ OK ]\n"), "[ \(wrap("OK", .ok)) ]\n")
    }

    func testWordBoundaries() {
        for text in ["terror", "Okay", "errored", "information", "uptime", "lookup", "stderr", "debugger", "error2",
                     "_error", "error_x", "okok", "warned", "denied1"] {
            XCTAssertEqual(run("a \(text) b\n"), "a \(text) b\n", text)
        }
    }

    func testPunctuationIsABoundary() {
        XCTAssertEqual(run("(error)\n"), "(\(wrap("error", .error)))\n")
        XCTAssertEqual(run("failed.\n"), "\(wrap("failed", .error)).\n")
        XCTAssertEqual(run("x=fatal,y\n"), "x=\(wrap("fatal", .error)),y\n")
        XCTAssertEqual(run("/var/log/error.log\n"), "/var/log/\(wrap("error", .error)).log\n")
        XCTAssertEqual(run("--verbose\n"), "--\(wrap("verbose", .debug))\n")
        XCTAssertEqual(run("\"ok\"\n"), "\"\(wrap("ok", .ok))\"\n")
    }

    func testSeveralMatchesInOneLine() {
        XCTAssertEqual(run("error: connection refused\n"),
                       "\(wrap("error", .error)): connection \(wrap("refused", .error))\n")
    }

    func testTextWithoutKeywordsIsUnchanged() {
        let text = "the quick brown fox jumps over the lazy dog 12345 !@#$%^&*()\r\n\t"
        XCTAssertEqual(run(text), text)
    }

    func testEmptyInput() {
        let highlighter = KeywordHighlighter(settings: .default)
        XCTAssertEqual(highlighter.process([]), [])
        XCTAssertEqual(highlighter.flush(), [])
    }

    // MARK: - Colours the program set are never overridden

    func testColouredTextUntouched() {
        let text = "\(Self.esc)[31merror\(Self.esc)[0m\n"
        XCTAssertEqual(run(text), text)
        let bright = "\(Self.esc)[91mERROR fatal\(Self.esc)[39m\n"
        XCTAssertEqual(run(bright), bright)
    }

    func testSGRResetRestoresHighlighting() {
        XCTAssertEqual(run("\(Self.esc)[32mok\(Self.esc)[0m ok\n"),
                       "\(Self.esc)[32mok\(Self.esc)[0m \(wrap("ok", .ok))\n")
        XCTAssertEqual(run("\(Self.esc)[32mok\(Self.esc)[m ok\n"),
                       "\(Self.esc)[32mok\(Self.esc)[m \(wrap("ok", .ok))\n")
        XCTAssertEqual(run("\(Self.esc)[1;32mok\(Self.esc)[39m ok\n"),
                       "\(Self.esc)[1;32mok\(Self.esc)[39m \(wrap("ok", .ok))\n")
        XCTAssertEqual(run("\(Self.esc)[32;0mok\n"), "\(Self.esc)[32;0m\(wrap("ok", .ok))\n")
    }

    func testNonColourSGRKeepsHighlighting() {
        // Bold / underline / background don't change the foreground.
        XCTAssertEqual(run("\(Self.esc)[1;4;44m error\n"), "\(Self.esc)[1;4;44m \(wrap("error", .error))\n")
    }

    func testExtendedForegroundTracking() {
        let c256 = "\(Self.esc)[38;5;196merror\n"
        XCTAssertEqual(run(c256), c256)
        let truecolour = "\(Self.esc)[38;2;1;2;3merror\n"
        XCTAssertEqual(run(truecolour), truecolour)
        let colon = "\(Self.esc)[38:2::1:2:3merror\n"
        XCTAssertEqual(run(colon), colon)
        // 38;5;n followed by 0 in the same SGR → default again.
        XCTAssertEqual(run("\(Self.esc)[38;5;196;0m error\n"), "\(Self.esc)[38;5;196;0m \(wrap("error", .error))\n")
    }

    func testBackgroundArgumentsAreNotReadAsForeground() {
        // 48;5;31 is a background colour; the 31 is its argument, not "red foreground".
        XCTAssertEqual(run("\(Self.esc)[48;5;31m error\n"), "\(Self.esc)[48;5;31m \(wrap("error", .error))\n")
        XCTAssertEqual(run("\(Self.esc)[48;2;31;32;33m error\n"), "\(Self.esc)[48;2;31;32;33m \(wrap("error", .error))\n")
        // …and a background 0 argument isn't a reset: 38;5;1 then 48;5;0 keeps the foreground set.
        let text = "\(Self.esc)[38;5;1;48;5;0m error\n"
        XCTAssertEqual(run(text), text)
    }

    func testInverseVideoUntouched() {
        let text = "\(Self.esc)[7m error \(Self.esc)[27m"
        XCTAssertEqual(run(text + "ok\n"), text + wrap("ok", .ok) + "\n")
    }

    func testResetToInitialState() {
        XCTAssertEqual(run("\(Self.esc)[31m\(Self.esc)c error\n"), "\(Self.esc)[31m\(Self.esc)c \(wrap("error", .error))\n")
    }

    // MARK: - Escape sequences pass through unchanged

    func testCSIPassesThroughUnchanged() {
        let text = "\(Self.esc)[2J\(Self.esc)[H\(Self.esc)[10;20H\(Self.esc)[K\(Self.esc)[?25l plain\n"
        XCTAssertEqual(run(text), text)
    }

    func testKeywordsInsideEscapeSequencesAreNotTouched() {
        // OSC title containing keywords (BEL and ST terminated), DCS payload, APC.
        let osc = "\(Self.esc)]0;error ok fatal\u{07}"
        XCTAssertEqual(run(osc), osc)
        let oscST = "\(Self.esc)]2;error 10.0.0.1\(Self.esc)\\"
        XCTAssertEqual(run(oscST), oscST)
        let dcs = "\(Self.esc)Pq error warning\(Self.esc)\\"
        XCTAssertEqual(run(dcs), dcs)
        let apc = "\(Self.esc)_ok done\(Self.esc)\\"
        XCTAssertEqual(run(apc), apc)
        XCTAssertEqual(run(osc + " error\n"), osc + " " + wrap("error", .error) + "\n")
    }

    func testCharsetAndShortEscapes() {
        // ESC ( B, ESC 7, ESC =, ESC # 8 — the bytes after ESC aren't text.
        let text = "\(Self.esc)(B\(Self.esc)7\(Self.esc)=\(Self.esc)#8"
        XCTAssertEqual(run(text), text)
        XCTAssertEqual(run(text + "ok\n"), text + wrap("ok", .ok) + "\n")
    }

    func testEscapeAfterKeywordGoesAfterTheReset() {
        // "error" ends at the escape (next text is a space): highlight, then the escape verbatim.
        XCTAssertEqual(run("error\(Self.esc)[K\n"), wrap("error", .error) + "\(Self.esc)[K\n")
        XCTAssertEqual(run("ok\(Self.esc)[0m\r\n"), wrap("ok", .ok) + "\(Self.esc)[0m\r\n")
    }

    func testEscapeMidWordIsNotAWordBoundary() {
        // Visible text is "terror" / "error2": no match, bytes unchanged.
        let a = "t\(Self.esc)[1merror\n"
        XCTAssertEqual(run(a), a)
        let b = "error\(Self.esc)[1m2\n"
        XCTAssertEqual(run(b), b)
        let c = "err\(Self.esc)[0mor\n"
        XCTAssertEqual(run(c), c)
    }

    func testEscapeSequencesNeverGetInsertionsWhenSplit() {
        // Split everywhere: the CSI/OSC stays intact and the output is the same as unsplit.
        assertAllSplits("a \(Self.esc)[38;2;10;20;30merror\(Self.esc)[0m error\n",
                        "a \(Self.esc)[38;2;10;20;30merror\(Self.esc)[0m \(wrap("error", .error))\n")
        assertAllSplits("\(Self.esc)]0;ok error\u{07}ok\n", "\(Self.esc)]0;ok error\u{07}\(wrap("ok", .ok))\n")
        assertAllSplits("\(Self.esc)P1;2|error\(Self.esc)\\ fatal\n",
                        "\(Self.esc)P1;2|error\(Self.esc)\\ \(wrap("fatal", .error))\n")
    }

    func testLongOSCDoesNotGrowTheBuffer() {
        let payload = String(repeating: "A", count: 100_000)
        let text = "\(Self.esc)]52;c;\(payload)\u{07} ok\n"
        let highlighter = KeywordHighlighter(settings: .default)
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + 4096, bytes.count)
            let chunk = highlighter.process(bytes[index..<end])
            out += chunk
            index = end
        }
        out += highlighter.flush()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "\(Self.esc)]52;c;\(payload)\u{07} \(wrap("ok", .ok))\n")
    }

    // MARK: - Chunk boundaries

    func testMatchSplitAcrossChunks() {
        // Ruling I3: never hold text — a word cut by a chunk boundary is emitted plain (missed, not lagged).
        XCTAssertEqual(run(["an err", "or here\n"]), "an error here\n")
        XCTAssertEqual(run(["e", "r", "r", "o", "r", "\n"]), "error\n")
        XCTAssertEqual(run(["ter", "ror\n"]), "terror\n")
        XCTAssertEqual(run(["an error", " here\n"]), "an error here\n")
        XCTAssertEqual(run(["an ", "error here\n"]), "an \(wrap("error", .error)) here\n")
        assertAllSplits("x error y ok 192.168.1.10:22 aa:bb:cc:dd:ee:ff\n",
                        "x \(wrap("error", .error)) y \(wrap("ok", .ok)) \(wrap("192.168.1.10", .network)):22 \(wrap("aa:bb:cc:dd:ee:ff", .network))\n")
    }

    func testChunkEndingAtWhitespaceIsEmittedImmediately() {
        let highlighter = KeywordHighlighter(settings: .default)
        let out = highlighter.process(ArraySlice(Array("an error\n".utf8)))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "an \(wrap("error", .error))\n")
        XCTAssertEqual(highlighter.flush(), [])
        let space = highlighter.process(ArraySlice(Array("ok ".utf8)))
        XCTAssertEqual(String(decoding: space, as: UTF8.self), wrap("ok", .ok) + " ")
    }

    func testEchoedKeystrokeIsEmittedImmediately() {
        // Review I3: `process("e")` returned [] (typing lag until the idle flush).
        let highlighter = KeywordHighlighter(settings: .default)
        XCTAssertEqual(highlighter.process(ArraySlice(Array("e".utf8))), Array("e".utf8))
        XCTAssertEqual(highlighter.process(ArraySlice(Array("rror".utf8))), Array("rror".utf8))
        XCTAssertEqual(highlighter.flush(), [])
    }

    func testTrailingWordIsEmittedImmediately() {
        let highlighter = KeywordHighlighter(settings: .default)
        XCTAssertEqual(String(decoding: highlighter.process(ArraySlice(Array("status: do".utf8))), as: UTF8.self), "status: do")
        XCTAssertEqual(String(decoding: highlighter.process(ArraySlice(Array("ne".utf8))), as: UTF8.self), "ne")
        XCTAssertEqual(highlighter.flush(), [])
        // A word followed by an escape at the end of a chunk is emitted too.
        XCTAssertEqual(highlighter.process(ArraySlice(Array(" ok\u{1B}[0".utf8))), Array(" ok\u{1B}[0".utf8))
        XCTAssertEqual(String(decoding: highlighter.process(ArraySlice(Array("m error\n".utf8))), as: UTF8.self),
                       "m \(wrap("error", .error))\n")
    }

    func testFlushedPartialWordIsNotReMatchedWhenItContinues() {
        // "o" was flushed on idle; "k" continuing the same word must not be treated as a word start.
        let highlighter = KeywordHighlighter(settings: .default)
        var out = highlighter.process(ArraySlice(Array("o".utf8)))
        out += highlighter.flush()
        out += highlighter.process(ArraySlice(Array("kerror \n".utf8)))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "okerror \n")
    }

    func testHeldBytesAreBounded() {
        let highlighter = KeywordHighlighter(settings: .default)
        let long = String(repeating: "a", count: 200)
        let out = highlighter.process(ArraySlice(Array(long.utf8)))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), long)
        // A word glued to the end of a long run isn't a match.
        XCTAssertEqual(run(String(repeating: "x", count: 100) + "error\n"), String(repeating: "x", count: 100) + "error\n")
    }

    // MARK: - UTF-8

    func testUTF8IsPreservedAndNeverSplit() {
        let text = "café ✓ ok 日本語 error — done\n"
        let expected = "café ✓ \(wrap("ok", .ok)) 日本語 \(wrap("error", .error)) — \(wrap("done", .ok))\n"
        XCTAssertEqual(run(text), expected)
        assertAllSplits(text, expected)
        // Byte-at-a-time: every word is cut by a chunk boundary, so nothing is highlighted and nothing is held.
        let highlighter = KeywordHighlighter(settings: .default)
        var out: [UInt8] = []
        for byte in text.utf8 {
            let chunk = highlighter.process([byte])
            XCTAssertEqual(chunk, [byte])
            out += chunk
        }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), text)
    }

    func testNonASCIILettersAreWordCharacters() {
        // No match glued to non-ASCII letters (conservative boundary).
        XCTAssertEqual(run("erroré okä\n"), "erroré okä\n")
    }

    func testInvalidUTF8PassesThroughByteIdentical() {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x20] + Array("error".utf8) + [0x20, 0xC3] + Array(" ok\n".utf8)
        let highlighter = KeywordHighlighter(settings: .default)
        let out = highlighter.process(ArraySlice(bytes)) + highlighter.flush()
        let expected: [UInt8] = [0xFF, 0xFE, 0x20] + Array(wrap("error", .error).utf8) + [0x20, 0xC3]
            + Array(" \(wrap("ok", .ok))\n".utf8)
        XCTAssertEqual(out, expected)
    }

    // MARK: - Alternate screen

    func testTracksBracketedPasteMode() {
        let highlighter = KeywordHighlighter(settings: .default)
        XCTAssertFalse(highlighter.isBracketedPasteActive)
        _ = highlighter.process(ArraySlice(Array("\(Self.esc)[?20".utf8)))
        _ = highlighter.process(ArraySlice(Array("04h$ ".utf8)))
        XCTAssertTrue(highlighter.isBracketedPasteActive, "split across chunks")
        _ = highlighter.process(ArraySlice(Array("\(Self.esc)[?1;2004l".utf8)))
        XCTAssertFalse(highlighter.isBracketedPasteActive, "combined params")
        _ = highlighter.process(ArraySlice(Array("\(Self.esc)[?2004h\(Self.esc)c".utf8)))
        XCTAssertFalse(highlighter.isBracketedPasteActive, "RIS resets it")
        let disabled = KeywordHighlighter(settings: KeywordHighlightSettings.Snapshot(isEnabled: false))
        _ = disabled.process(ArraySlice(Array("\(Self.esc)[?2004h".utf8)))
        XCTAssertTrue(disabled.isBracketedPasteActive, "tracked even when highlighting is off")
    }

    func testAlternateScreenDisablesHighlighting() {
        for mode in ["1049", "47", "1047"] {
            let on = "\(Self.esc)[?\(mode)h"
            let off = "\(Self.esc)[?\(mode)l"
            XCTAssertEqual(run("\(on)error ok\(off) error\n"), "\(on)error ok\(off) \(wrap("error", .error))\n", mode)
        }
        XCTAssertEqual(run("\(Self.esc)[?1;1049h error\n"), "\(Self.esc)[?1;1049h error\n")
        let highlighter = KeywordHighlighter(settings: .default)
        _ = highlighter.process(ArraySlice(Array("\(Self.esc)[?1049h".utf8)))
        XCTAssertTrue(highlighter.isAlternateScreenActive)
        _ = highlighter.process(ArraySlice(Array("\(Self.esc)[?1049l".utf8)))
        XCTAssertFalse(highlighter.isAlternateScreenActive)
    }

    func testAlternateScreenSplitAcrossChunks() {
        assertAllSplits("\(Self.esc)[?1049herror\(Self.esc)[?1049l ok\n",
                        "\(Self.esc)[?1049herror\(Self.esc)[?1049l \(wrap("ok", .ok))\n")
    }

    func testOtherPrivateModesDoNotToggleAlternateScreen() {
        XCTAssertEqual(run("\(Self.esc)[?25h\(Self.esc)[?2004h error\n"),
                       "\(Self.esc)[?25h\(Self.esc)[?2004h \(wrap("error", .error))\n")
    }

    // MARK: - IP addresses and MACs

    func testIPv4() {
        XCTAssertEqual(run("ping 8.8.8.8\n"), "ping \(wrap("8.8.8.8", .network))\n")
        XCTAssertEqual(run("192.168.99.197\n"), "\(wrap("192.168.99.197", .network))\n")
        XCTAssertEqual(run("net 10.0.0.0/24\n"), "net \(wrap("10.0.0.0", .network))/24\n")
        XCTAssertEqual(run("to 127.0.0.1:8080 ok\n"), "to \(wrap("127.0.0.1", .network)):8080 \(wrap("ok", .ok))\n")
        XCTAssertEqual(run("(255.255.255.0)\n"), "(\(wrap("255.255.255.0", .network)))\n")
        XCTAssertEqual(run("from 1.2.3.4.\n"), "from \(wrap("1.2.3.4", .network)).\n")
    }

    func testNotIPv4() {
        for text in ["256.1.1.1", "1.2.3", "1.2.3.4.5", "a1.2.3.4", "1.2.3.4a", "1..2.3", "1234.1.1.1", "v1.2.3.4x", "1.2.3.4.5.6"] {
            XCTAssertEqual(run("x \(text) y\n"), "x \(text) y\n", text)
        }
    }

    func testIPv6() {
        for address in ["::1", "fe80::1", "2001:db8::8a2e:370:7334", "2001:0db8:0000:0000:0000:ff00:0042:8329",
                        "fe80::1ff:fe23:4567:890a", "::ffff:192.168.1.1", "2001:DB8::1", "fe80::"] {
            XCTAssertEqual(run("addr \(address) y\n"), "addr \(wrap(address, .network)) y\n", address)
        }
        XCTAssertEqual(run("[2001:db8::1]:22\n"), "[\(wrap("2001:db8::1", .network))]:22\n")
        XCTAssertEqual(run("fe80::/10\n"), "\(wrap("fe80::", .network))/10\n")
        XCTAssertEqual(run("inet6 ::1.\n"), "inet6 \(wrap("::1", .network)).\n")
    }

    func testNotIPv6() {
        for text in ["12:34:56", "std::vector", "Foo::Bar", "a::b", "::", "1:2:3:4:5:6:7:8:9", "1::2::3", "12345::1",
                     "fe80::1g", "dead:beef"] {
            XCTAssertEqual(run("x \(text) y\n"), "x \(text) y\n", text)
        }
    }

    func testMAC() {
        XCTAssertEqual(run("ether aa:bb:cc:dd:ee:ff brd\n"), "ether \(wrap("aa:bb:cc:dd:ee:ff", .network)) brd\n")
        XCTAssertEqual(run("ether AA-BB-CC-00-11-22\n"), "ether \(wrap("AA-BB-CC-00-11-22", .network))\n")
        XCTAssertEqual(run("02:42:ac:11:00:02,\n"), "\(wrap("02:42:ac:11:00:02", .network)),\n")
    }

    func testNotMAC() {
        for text in ["aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "aa:bb-cc:dd:ee:ff", "aa:bb:cc:dd:ee:fg", "aaa:bb:cc:dd:ee:ff"] {
            XCTAssertEqual(run("x \(text) y\n"), "x \(text) y\n", text)
        }
    }

    // MARK: - Settings

    func testDisabledIsByteIdenticalPassthrough() {
        var settings = KeywordHighlightSettings.Snapshot.default
        settings.isEnabled = false
        let highlighter = KeywordHighlighter(settings: settings)
        let bytes: [UInt8] = Array("error ok 10.0.0.1 \u{1B}[31mfatal\u{1B}[0m warn".utf8) + [0xFF, 0xC3]
        XCTAssertEqual(highlighter.process(ArraySlice(bytes)), bytes)
        XCTAssertEqual(highlighter.flush(), [])
    }

    func testCustomColours() {
        var settings = KeywordHighlightSettings.Snapshot.default
        settings.colors[.error] = RGBColor(red: 1, green: 2, blue: 3)
        XCTAssertEqual(run(["error\n"], settings: settings), "\u{1B}[38;2;1;2;3merror\u{1B}[39m\n")
    }

    func testUpdateSettingsLiveKeepsTerminalState() {
        let highlighter = KeywordHighlighter(settings: .default)
        _ = highlighter.process(ArraySlice(Array("\u{1B}[31m".utf8)))
        var off = KeywordHighlightSettings.Snapshot.default
        off.isEnabled = false
        highlighter.update(settings: off)
        XCTAssertEqual(highlighter.process(ArraySlice(Array("error \u{1B}[0m".utf8))), Array("error \u{1B}[0m".utf8))
        highlighter.update(settings: .default)
        XCTAssertEqual(String(decoding: highlighter.process(ArraySlice(Array("error\n".utf8))), as: UTF8.self),
                       wrap("error", .error) + "\n")
        highlighter.update(settings: off)
        XCTAssertEqual(String(decoding: highlighter.process(ArraySlice(Array("fatal\n".utf8))), as: UTF8.self), "fatal\n")
    }

    // MARK: - Review fix round

    private func e(_ s: String) -> String { "\u{1B}" + s }

    func testSavedCursorAttributesAreRestored() {
        // I1, the reviewer's inputs: the restored attribute is red, so nothing may be recoloured.
        for text in [e("[31m") + e("7") + e("[0m") + e("8") + "error here\n",
                     e("[31m") + e("[s") + e("[0m") + e("[u") + "error here\n",
                     e("[31m") + e("[?1049h") + e("[0m") + " " + e("[?1049l") + "error\n",
                     e("[31m") + e("[?1048h") + e("[0m") + e("[?1048l") + "error\n"] {
            XCTAssertEqual(run(text), text, text.debugDescription)
        }
        // Restoring a saved default (or nothing saved) gives the default foreground.
        XCTAssertEqual(run(e("7") + e("[31m") + e("8") + "error\n"), e("7") + e("[31m") + e("8") + wrap("error", .error) + "\n")
        XCTAssertEqual(run(e("[31m") + e("8") + "error\n"), e("[31m") + e("8") + wrap("error", .error) + "\n")
        // Each screen has its own saved slot (ESC 7 on the alternate screen doesn't touch the main one).
        let perScreen = e("[31m") + e("7") + e("[?1049h") + e("[0m") + e("7") + e("[?1049l") + e("8") + " error\n"
        XCTAssertEqual(run(perScreen), perScreen)
        // DECSTR resets the saved attribute.
        let soft = e("[31m") + e("7") + e("[!p") + e("8") + " error\n"
        XCTAssertEqual(run(soft), e("[31m") + e("7") + e("[!p") + e("8") + " " + wrap("error", .error) + "\n")
        // With DECLRMM (?69h) on, CSI s sets margins instead of saving.
        let margins = e("[31m") + e("[s") + e("[?69h") + e("[0m") + e("[s") + e("[u") + " error\n"
        XCTAssertEqual(run(margins), margins)
        let noMargins = e("[31m") + e("[s") + e("[0m") + e("[s") + e("[u") + " error\n"
        XCTAssertEqual(run(noMargins), e("[31m") + e("[s") + e("[0m") + e("[s") + e("[u") + " " + wrap("error", .error) + "\n")
    }

    func testOnlyOSCAndAPCEndOnBEL() {
        // I2, the reviewer's inputs: DCS and PM (and SOS) stay open across BEL.
        for text in [e("P1$q") + "\u{07} error " + e("\\"),
                     e("^x") + "\u{07} ok " + e("\\"),
                     e("Xx") + "\u{07} ok " + e("\\")] {
            XCTAssertEqual(run(text), text, text.debugDescription)
        }
        XCTAssertEqual(run(e("_x") + "\u{07} ok\n"), e("_x") + "\u{07} " + wrap("ok", .ok) + "\n")
        XCTAssertEqual(run(e("]0;t") + "\u{07} ok\n"), e("]0;t") + "\u{07} " + wrap("ok", .ok) + "\n")
        // 8-bit ST ends DCS / SOS / PM.
        for intro in ["P1$q", "^", "X"] {
            let bytes = Array(e(intro).utf8) + Array("x".utf8) + [0x9C] + Array(" error\n".utf8)
            let highlighter = KeywordHighlighter(settings: .default)
            let expected = Array(e(intro).utf8) + Array("x".utf8) + [0x9C] + Array(" \(wrap("error", .error))\n".utf8)
            XCTAssertEqual(highlighter.process(ArraySlice(bytes)), expected, intro)
        }
    }

    func testDELInsideEscapeIsIgnored() {
        // M4, the reviewer's inputs: SwiftTerm ignores DEL there, so the red applies.
        for text in [e("[3") + "\u{7F}1m error\n", e("") + "\u{7F}[31m error\n"] {
            XCTAssertEqual(run(text), text, text.debugDescription)
        }
    }

    func testNetworkAddressAfterColonOrDash() {
        // M6.
        XCTAssertEqual(run("ip:192.168.1.1\n"), "ip:\(wrap("192.168.1.1", .network))\n")
        XCTAssertEqual(run("src:10.0.0.1 x\n"), "src:\(wrap("10.0.0.1", .network)) x\n")
        XCTAssertEqual(run("eth0-aa:bb:cc:dd:ee:ff\n"), "eth0-\(wrap("aa:bb:cc:dd:ee:ff", .network))\n")
        XCTAssertEqual(run("addr:fe80::1\n"), "addr:\(wrap("fe80::1", .network))\n")
        XCTAssertEqual(run("x=10.0.0.1 (10.0.0.2)\n"), "x=\(wrap("10.0.0.1", .network)) (\(wrap("10.0.0.2", .network)))\n")
        // Still bounded: no match inside longer address-like runs or version strings.
        XCTAssertEqual(run("1.2.3.4:5.6.7.8\n"), "\(wrap("1.2.3.4", .network)):5.6.7.8\n")
        for text in ["12:10.0.0.1", "v1.2.3.4.5", "aa:bb:cc:dd:ee:ff:00", "1.2.3.4.5.6.7.8", "ab-10.0.0.1", "1:2:3:4:5:6:7:8:9"] {
            XCTAssertEqual(run("x \(text) y\n"), "x \(text) y\n", text)
        }
    }

    func testCSIParameterHandlingMatchesSwiftTerm() {
        // M9: SwiftTerm drops a CSI with more than 24 parameters entirely…
        let tooMany = e("[31" + String(repeating: ";1", count: 24) + "m") + " error\n"
        XCTAssertEqual(run(tooMany), e("[31" + String(repeating: ";1", count: 24) + "m") + " " + wrap("error", .error) + "\n")
        let limit = e("[31" + String(repeating: ";1", count: 23) + "m") + " error\n"
        XCTAssertEqual(run(limit), limit)
        // …but has no byte limit on digits.
        let longDigits = e("[" + String(repeating: "0", count: 300) + "31m") + " error\n"
        XCTAssertEqual(run(longDigits), longDigits)
        // 38 without a valid colour form leaves the foreground as it was.
        XCTAssertEqual(run(e("[38;9m") + " error\n"), e("[38;9m") + " " + wrap("error", .error) + "\n")
        XCTAssertEqual(run(e("[38m") + " error\n"), e("[38m") + " " + wrap("error", .error) + "\n")
        // 4:3 (curly underline) consumes its sub-parameter; the 3 isn't anything else.
        XCTAssertEqual(run(e("[4:3m") + " error\n"), e("[4:3m") + " " + wrap("error", .error) + "\n")
        // Private / intermediate forms of m aren't SGR.
        XCTAssertEqual(run(e("[>4;31m") + " error\n"), e("[>4;31m") + " " + wrap("error", .error) + "\n")
    }

    // MARK: - Performance

    func testPerformanceOneMegabyteOfLogText() {
        let lines = [
            "2026-11-15T00:23:01Z INFO  sshd[1234]: Accepted publickey for cory from 192.168.99.10 port 52311 ssh2\n",
            "2026-11-15T00:23:02Z ERROR kernel: eth0 aa:bb:cc:dd:ee:ff link failed, retrying (attempt 3)\n",
            "2026-11-15T00:23:03Z \u{1B}[33mWARN\u{1B}[0m  docker: container web is running; deprecated flag --link\n",
            "2026-11-15T00:23:04Z DEBUG resolver: fe80::1ff:fe23:4567:890a -> ok, cache hit ratio 0.93\n",
        ]
        var text: [UInt8] = []
        while text.count < 1_048_576 { for line in lines { text += Array(line.utf8) } }
        let highlighter = KeywordHighlighter(settings: .default)
        let start = Date()
        var outCount = 0
        var index = 0
        while index < text.count {
            let end = min(index + 16_384, text.count)
            outCount += highlighter.process(text[index..<end]).count
            index = end
        }
        outCount += highlighter.flush().count
        let elapsed = Date().timeIntervalSince(start)
        print("KeywordHighlighter: \(text.count) bytes in \(String(format: "%.1f", elapsed * 1000)) ms → \(outCount) bytes")
        XCTAssertGreaterThan(outCount, text.count)
        XCTAssertLessThan(elapsed, 5.0, "generous bound for unoptimised debug builds")
    }
}
