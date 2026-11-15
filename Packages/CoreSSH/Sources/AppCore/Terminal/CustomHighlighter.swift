import Foundation

/// Applies the custom highlighting rules (Settings → Highlighting) to terminal output as it
/// streams in. It runs before `KeywordHighlighter`: text it colours no longer has the default
/// foreground, so the built-in keyword colours never paint over it (custom rules win where they
/// overlap built-in highlights).
///
/// Rules:
/// - Matching works on runs of printed text: the bytes between line breaks, other control
///   characters (TAB excepted) and escape sequences, within one chunk of output. A match never
///   spans an escape sequence or a line break, and a phrase cut by a chunk boundary is not
///   highlighted (as with keywords, nothing is ever held back, so typing never lags). Nor is a
///   word or phrase whose whole-word guard touches a chunk boundary, as the word may go on in
///   the other chunk (`prod|uction`): text at the start of a chunk counts as cut when the
///   previous chunk ended in a word character (or any non-ASCII byte), and text at the end of a
///   chunk always does. A missed highlight, never a wrong one.
/// - Only text in the default foreground, not inverse, on the normal screen is recoloured (the
///   same rule and parser as keywords: `TerminalOutputParser`). Off in vim, htop, less, ….
/// - The only change made to the stream is inserting `ESC[38;2;R;G;Bm` (with `1;` for bold) before
///   a match and `ESC[39m` (`ESC[22;39m` after bold) after it, always at UTF-8 character
///   boundaries. Bold is only added where the text is neither bold nor faint already (SGR 22 would
///   clear both). Every input byte is emitted, in order.
/// - A run that isn't valid UTF-8 (besides a character cut at either end of the chunk, which is
///   passed through plain) is not matched.
/// - Matching work is bounded (see `CompiledHighlightRules`): each `process` call has
///   `matchBudgetPerChunk` of matching time; the rest of a chunk that needs more passes plain.
/// - Floods skip matching altogether: a chunk larger than `floodChunkSize` that arrives less than
///   `floodInterval` after the previous one (`cat` of a big log, `yes`) passes through plain, so
///   the terminal keeps up and stays responsive. Highlighting resumes as soon as output slows.
///
/// Threading: like `KeywordHighlighter`, one instance per tab, used from one thread or actor at a time.
public final class CustomHighlighter {
    /// Matching time allowed per `process` call (layer 3 in `CompiledHighlightRules`).
    public static let matchBudgetPerChunk: Duration = .milliseconds(25)
    /// A chunk larger than this (bytes) that follows the previous one within `floodInterval` is a flood.
    public static let floodChunkSize = 16 * 1024
    public static let floodInterval: Duration = .milliseconds(10)

    public private(set) var rules: CompiledHighlightRules
    private var parser = TerminalOutputParser()
    /// Printed text of the current run (all recolourable), not yet emitted. Emptied before `process` returns.
    private var run: [UInt8] = []
    /// The current run began at the start of this chunk, right after a word character that ended
    /// the previous chunk: a match touching its start may be part of a longer word.
    private var runContinuesPreviousChunk = false
    /// The last byte seen so far was printed text and a word character (or non-ASCII); an empty
    /// chunk leaves it as it was.
    private var previousChunkEndedInWord = false
    private var previousChunkAt: ContinuousClock.Instant?
    private let now: () -> ContinuousClock.Instant

    /// `now` is the clock for flood detection (injected by tests).
    public init(rules: CompiledHighlightRules = .empty, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.rules = rules
        self.now = now
    }

    /// Live rules change; keeps the terminal state.
    public func update(rules: CompiledHighlightRules) {
        self.rules = rules
    }

    /// Processes the next chunk of output; returns all of it (plus inserted colour codes).
    public func process(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        let arrivedAt = now()
        let isFlood = bytes.count > Self.floodChunkSize
            && previousChunkAt.map { arrivedAt - $0 < Self.floodInterval } ?? false
        previousChunkAt = arrivedAt
        let continuesWord = previousChunkEndedInWord
        if rules.isEmpty || isFlood {
            // Still track the terminal state so later output (and rules added later) start correct.
            for b in bytes {
                if parser.isTextByte(b) {
                    previousChunkEndedInWord = Self.isWordByte(b)
                } else {
                    previousChunkEndedInWord = false
                    parser.consumeSequenceByte(b)
                }
            }
            return Array(bytes)
        }
        let budget = CompiledHighlightRules.MatchBudget.starting(allowance: Self.matchBudgetPerChunk)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 32)
        var isFirstByte = true
        for b in bytes {
            defer { isFirstByte = false }
            if parser.isTextByte(b) {
                previousChunkEndedInWord = Self.isWordByte(b)
                if Self.isRunByte(b), parser.canRecolour {
                    if run.isEmpty { runContinuesPreviousChunk = isFirstByte && continuesWord }
                    run.append(b)
                } else {
                    flushRun(&out, budget, atChunkEnd: false)
                    out.append(b)
                }
            } else {
                previousChunkEndedInWord = false
                flushRun(&out, budget, atChunkEnd: false)
                out.append(b)
                parser.consumeSequenceByte(b)
            }
        }
        flushRun(&out, budget, atChunkEnd: true)
        return out
    }

    /// ASCII letters, digits and `_`, and every byte ≥ 0x80 (as `KeywordHighlighter` counts them):
    /// a chunk ending in one may have cut a word.
    @inline(__always)
    private static func isWordByte(_ b: UInt8) -> Bool {
        b >= 0x80 || b == 0x5F || (b >= 0x30 && b <= 0x39) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A)
    }

    /// Printable bytes (including every byte of UTF-8 sequences) and TAB.
    @inline(__always)
    private static func isRunByte(_ b: UInt8) -> Bool {
        (b >= 0x20 && b != 0x7F) || b == 0x09
    }

    /// `atChunkEnd`: the run reaches the end of the chunk (the text may go on in the next one).
    private func flushRun(_ out: inout [UInt8], _ budget: CompiledHighlightRules.MatchBudget, atChunkEnd: Bool) {
        guard !run.isEmpty else { return }
        defer { run.removeAll(keepingCapacity: true) }
        // A character cut by the chunk boundary: its continuation bytes at the start, its first
        // bytes at the end. Those pass through plain.
        var start = 0
        while start < run.count, run[start] & 0xC0 == 0x80 { start += 1 }
        let end = Self.endOfCompleteText(run, from: start)
        guard start < end, let line = String(bytes: run[start..<end], encoding: .utf8) else {
            out.append(contentsOf: run)
            return
        }
        // A run that starts with a cut character (start > 0) continues the previous chunk too.
        let matches = rules.matches(in: line, budget: budget, openStart: runContinuesPreviousChunk || start > 0,
                                    openEnd: atChunkEnd)
        out.append(contentsOf: run[0..<start])
        var position = start
        let attributes = parser.attributes
        let canBold = !attributes.bold && !attributes.faint
        for match in matches {
            let lower = start + match.range.lowerBound
            let upper = start + match.range.upperBound
            guard lower >= position, upper <= end else { continue }
            let bold = match.style.isBold && canBold
            out.append(contentsOf: run[position..<lower])
            let c = match.style.color
            out.append(contentsOf: Array("\u{1B}[\(bold ? "1;" : "")38;2;\(c.red);\(c.green);\(c.blue)m".utf8))
            out.append(contentsOf: run[lower..<upper])
            out.append(contentsOf: bold ? Self.closeBold : Self.close)
            position = upper
        }
        out.append(contentsOf: run[position...])
    }

    private static let close: [UInt8] = Array("\u{1B}[39m".utf8)
    private static let closeBold: [UInt8] = Array("\u{1B}[22;39m".utf8)

    /// The end of `bytes` without a trailing, incomplete UTF-8 sequence.
    private static func endOfCompleteText(_ bytes: [UInt8], from start: Int) -> Int {
        let count = bytes.count
        var i = count - 1
        var continuation = 0
        while i >= start, bytes[i] & 0xC0 == 0x80, continuation < 3 {
            continuation += 1
            i -= 1
        }
        guard i >= start else { return count }
        let lead = bytes[i]
        let expected: Int
        switch lead {
        case 0x00..<0x80: return count
        case 0xC0..<0xE0: expected = 1
        case 0xE0..<0xF0: expected = 2
        case 0xF0..<0xF8: expected = 3
        default: return count // invalid; String(bytes:) rejects the run
        }
        return continuation < expected ? i : count
    }
}
