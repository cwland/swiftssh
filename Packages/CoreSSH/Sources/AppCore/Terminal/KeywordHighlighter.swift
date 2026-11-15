import Foundation

/// Recolours keywords, IP addresses and MAC addresses in terminal output as it streams in.
///
/// Rules (v0.6.1 plan, Additions §2):
/// - Only text whose current foreground is the terminal default is recoloured (and not while SGR 7
///   inverse video is on); colours the program set are never overridden.
/// - The only change ever made to the stream is inserting `ESC[38;2;R;G;Bm` before a match and
///   `ESC[39m` (default foreground) after it. Every input byte is emitted, in order. Nothing is ever
///   inserted inside an escape sequence (CSI, OSC, DCS, SOS/PM/APC, ESC-intermediate), whether or not
///   it arrives split across chunks.
/// - Off while the alternate screen is active (`CSI ? 1049/1047/47 h` … `l`), e.g. vim/htop/less.
/// - Matches are whole words, case-insensitive. Word characters are ASCII letters, digits, `_` and
///   every byte ≥ 0x80 (so nothing is matched glued to a non-ASCII letter, and insertions only ever
///   happen next to ASCII bytes — UTF-8 sequences are never split). A word interrupted by an escape
///   sequence (`err ESC[0m or`) is not a match.
///
/// Streaming: a trailing run of word-ish bytes (letters, digits, `_ . : -`, non-ASCII) that might
/// continue in the next chunk is held back, at most `maxHeldBytes` (with any escape sequences right
/// after it); a chunk that ends at whitespace/newline/punctuation leaves nothing held. Call `flush()`
/// when output goes idle (~50 ms) to release a held word (e.g. a prompt ending in "ok").
///
/// Threading: not Sendable and not actor-isolated — one instance per tab, used from one thread or
/// actor at a time (create it where the output is processed). Settings arrive as a Sendable
/// `KeywordHighlightSettings.Snapshot`.
public final class KeywordHighlighter {
    /// Upper bound on bytes held back between `process` calls.
    public static let maxHeldBytes = 64

    public private(set) var settings: KeywordHighlightSettings.Snapshot
    /// True between `CSI ? 1049 h` (or 47/1047) and the matching `l`. Tracked even when disabled.
    public private(set) var isAlternateScreenActive = false

    private var openSequences: [[UInt8]] = []
    private static let closeSequence: [UInt8] = [0x1B, 0x5B, 0x33, 0x39, 0x6D] // ESC [ 3 9 m

    private enum ParseState { case ground, escape, escapeIntermediate, csi, string, stringEscape }
    private var state = ParseState.ground
    private var csiBytes: [UInt8] = []
    private var csiOverflow = false
    private static let maxCSIBytes = 256

    private var foregroundIsDefault = true
    private var inverse = false

    /// Bytes not yet emitted: `tokenLength` text bytes of a candidate word, then (if `heldEscape`)
    /// escape-sequence bytes that followed it.
    private var held: [UInt8] = []
    private var tokenLength = 0
    private var heldEscape = false
    /// Inside a run of token bytes that can't be matched (started mid-word, coloured, overflowed…);
    /// passes straight through until the next break byte.
    private var passthroughToken = false

    /// `settings.isEnabled == false` makes the output byte-identical to the input (state is still
    /// tracked so turning it on later is correct).
    public init(settings: KeywordHighlightSettings.Snapshot = .default) {
        self.settings = settings
        held.reserveCapacity(Self.maxHeldBytes + 8)
        buildSequences()
    }

    /// Live settings change; keeps the terminal state (colours, alternate screen). A word already held
    /// is resolved with the new settings (plain if now disabled).
    public func update(settings: KeywordHighlightSettings.Snapshot) {
        self.settings = settings
        buildSequences()
    }

    /// Processes the next chunk of terminal output; returns the bytes to feed the terminal now.
    public func process(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 4 + held.count + 16)
        for byte in bytes { step(byte, &out) }
        return out
    }

    /// Releases anything held back (call on idle). A held word is treated as complete.
    public func flush() -> [UInt8] {
        guard tokenLength > 0 else { return [] }
        var out: [UInt8] = []
        resolveToken(&out)
        // If more of the same word arrives later, don't match its tail as a fresh word.
        passthroughToken = true
        return out
    }

    // MARK: - Byte state machine

    private var canHighlight: Bool {
        settings.isEnabled && foregroundIsDefault && !inverse && !isAlternateScreenActive
    }

    @inline(__always)
    private func step(_ b: UInt8, _ out: inout [UInt8]) {
        switch state {
        case .ground: ground(b, &out)
        case .escape: escape(b, &out)
        case .escapeIntermediate:
            emitEscapeByte(b, &out)
            switch b {
            case 0x20...0x2F, 0x00...0x17, 0x19, 0x1C...0x1F: break
            case 0x1B: state = .escape
            default: state = .ground
            }
        case .csi: csi(b, &out)
        case .string:
            emitEscapeByte(b, &out)
            switch b {
            case 0x07, 0x18, 0x1A: state = .ground
            case 0x1B: state = .stringEscape
            default: break
            }
        case .stringEscape:
            if b == 0x5C { // ST = ESC \
                emitEscapeByte(b, &out)
                state = .ground
            } else { // ESC inside a string starts a new sequence
                state = .escape
                escape(b, &out)
            }
        }
    }

    @inline(__always)
    private func ground(_ b: UInt8, _ out: inout [UInt8]) {
        if b == 0x1B {
            emitEscapeByte(b, &out)
            state = .escape
            return
        }
        if KeywordMatcher.isToken(b) {
            if tokenLength > 0 {
                if heldEscape { // an escape sequence inside the word: not a whole-word match
                    emitHeldRaw(&out)
                    passthroughToken = true
                    out.append(b)
                } else {
                    held.append(b)
                    tokenLength += 1
                    if held.count > Self.maxHeldBytes {
                        emitHeldRaw(&out)
                        passthroughToken = true
                    }
                }
            } else if passthroughToken {
                out.append(b)
            } else if canHighlight {
                held.append(b)
                tokenLength = 1
            } else {
                passthroughToken = true
                out.append(b)
            }
        } else {
            if tokenLength > 0 { resolveToken(&out) }
            passthroughToken = false
            out.append(b)
        }
    }

    private func escape(_ b: UInt8, _ out: inout [UInt8]) {
        emitEscapeByte(b, &out)
        switch b {
        case 0x5B: // [
            state = .csi
            csiBytes.removeAll(keepingCapacity: true)
            csiOverflow = false
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .string // ] P X ^ _
        case 0x1B: break
        case 0x18, 0x1A: state = .ground
        case 0x20...0x2F: state = .escapeIntermediate
        case 0x63: // ESC c — full reset
            foregroundIsDefault = true
            inverse = false
            isAlternateScreenActive = false
            state = .ground
        case 0x00...0x1F: break // C0 controls execute without ending the sequence
        default: state = .ground
        }
    }

    private func csi(_ b: UInt8, _ out: inout [UInt8]) {
        emitEscapeByte(b, &out)
        switch b {
        case 0x40...0x7E:
            if !csiOverflow { interpretCSI(final: b) }
            state = .ground
        case 0x20...0x3F:
            if csiBytes.count < Self.maxCSIBytes { csiBytes.append(b) } else { csiOverflow = true }
        case 0x1B: state = .escape
        case 0x18, 0x1A, 0x7F...0xFF: state = .ground
        default: break
        }
    }

    /// Escape-sequence bytes go behind a held word (so insertions land before them) or straight out.
    @inline(__always)
    private func emitEscapeByte(_ b: UInt8, _ out: inout [UInt8]) {
        if tokenLength > 0 {
            held.append(b)
            heldEscape = true
            if held.count > Self.maxHeldBytes {
                emitHeldRaw(&out)
                passthroughToken = true
            }
        } else {
            out.append(b)
        }
    }

    private func emitHeldRaw(_ out: inout [UInt8]) {
        out.append(contentsOf: held)
        clearHeld()
    }

    private func clearHeld() {
        held.removeAll(keepingCapacity: true)
        tokenLength = 0
        heldEscape = false
    }

    private func resolveToken(_ out: inout [UInt8]) {
        let matches = settings.isEnabled
            ? held.withUnsafeBufferPointer { KeywordMatcher.matches(in: UnsafeBufferPointer(rebasing: $0[0..<tokenLength])) }
            : []
        var position = 0
        for match in matches {
            out.append(contentsOf: held[position..<match.start])
            out.append(contentsOf: openSequences[match.category.index])
            out.append(contentsOf: held[match.start..<match.end])
            out.append(contentsOf: Self.closeSequence)
            position = match.end
        }
        out.append(contentsOf: held[position...])
        clearHeld()
    }

    // MARK: - CSI interpretation

    private func interpretCSI(final: UInt8) {
        switch final {
        case 0x6D: // m — SGR, only without private prefix or intermediates
            if csiBytes.allSatisfy({ (0x30...0x3B).contains($0) }) { applySGR() }
        case 0x68, 0x6C: // h / l
            guard csiBytes.first == 0x3F else { return } // ?
            let on = final == 0x68
            for value in Self.numbers(csiBytes.dropFirst()) where value == 1049 || value == 1047 || value == 47 {
                isAlternateScreenActive = on
            }
        case 0x70: // p — DECSTR (CSI ! p) soft reset
            if csiBytes == [0x21] {
                foregroundIsDefault = true
                inverse = false
            }
        default: break
        }
    }

    private func applySGR() {
        // Each parameter: its first number, and whether it carried ':' sub-parameters.
        var params: [(value: Int, hasSub: Bool)] = []
        var value = 0
        var inSub = false
        var hasSub = false
        for b in csiBytes {
            switch b {
            case 0x30...0x39:
                if !inSub { value = min(value * 10 + Int(b - 0x30), 100_000) }
            case 0x3A: // :
                inSub = true
                hasSub = true
            default: // ;
                params.append((value, hasSub))
                value = 0
                inSub = false
                hasSub = false
            }
        }
        params.append((value, hasSub))

        var index = 0
        while index < params.count {
            let (code, sub) = params[index]
            switch code {
            case 0:
                foregroundIsDefault = true
                inverse = false
            case 39: foregroundIsDefault = true
            case 30...37, 90...97: foregroundIsDefault = false
            case 7: inverse = true
            case 27: inverse = false
            case 38, 48, 58:
                if code == 38 { foregroundIsDefault = false }
                if !sub, index + 1 < params.count {
                    switch params[index + 1].value {
                    case 5: index += 2
                    case 2: index += 4
                    default: index += 1
                    }
                }
            default: break
            }
            index += 1
        }
    }

    private static func numbers(_ bytes: ArraySlice<UInt8>) -> [Int] {
        var result: [Int] = []
        var value = 0
        for b in bytes {
            if (0x30...0x39).contains(b) {
                value = min(value * 10 + Int(b - 0x30), 100_000)
            } else {
                result.append(value)
                value = 0
            }
        }
        result.append(value)
        return result
    }

    private func buildSequences() {
        openSequences = KeywordCategory.allCases.map { category in
            let color = settings.color(for: category)
            return Array("\u{1B}[38;2;\(color.red);\(color.green);\(color.blue)m".utf8)
        }
    }
}

extension KeywordCategory {
    /// Position in `allCases`.
    var index: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .ok: 2
        case .info: 3
        case .debug: 4
        case .network: 5
        }
    }
}

/// Finds matches inside one complete token (a run of token bytes bounded by break bytes).
enum KeywordMatcher {
    struct Match: Equatable {
        var start: Int
        var end: Int
        var category: KeywordCategory
    }

    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    @inline(__always) static func isLetter(_ b: UInt8) -> Bool {
        let lower = b | 0x20
        return b < 0x80 && lower >= 0x61 && lower <= 0x7A
    }

    @inline(__always) static func isHex(_ b: UInt8) -> Bool {
        let lower = b | 0x20
        return isDigit(b) || (b < 0x80 && lower >= 0x61 && lower <= 0x66)
    }

    /// Letters, digits, `_`, any non-ASCII byte.
    @inline(__always) static func isWord(_ b: UInt8) -> Bool {
        b >= 0x80 || isDigit(b) || isLetter(b) || b == 0x5F
    }

    /// Word bytes plus `.` `:` `-` (needed inside IPs and MACs).
    @inline(__always) static func isToken(_ b: UInt8) -> Bool {
        isWord(b) || b == 0x2E || b == 0x3A || b == 0x2D
    }

    /// Keywords packed 5 bits per lowercase letter (a=1…z=26), so lookup needs no allocation.
    private static let keywordTable: [UInt64: KeywordCategory] = {
        var table: [UInt64: KeywordCategory] = [:]
        for category in KeywordCategory.allCases {
            for word in category.keywords { table[pack(Array(word.utf8))!] = category }
        }
        return table
    }()

    private static let maxKeywordLength = 12

    private static func pack<C: Collection>(_ bytes: C) -> UInt64? where C.Element == UInt8 {
        var key: UInt64 = 0
        for b in bytes {
            guard isLetter(b) else { return nil }
            key = key << 5 | UInt64((b | 0x20) - 0x60)
        }
        return key
    }

    static func matches(in t: UnsafeBufferPointer<UInt8>) -> [Match] {
        var result: [Match] = []
        let n = t.count
        var i = 0
        while i < n {
            let b = t[i]
            if isHex(b) || b == 0x3A {
                let boundary = i == 0 || { let p = t[i - 1]; return !(isWord(p) || p == 0x2E || p == 0x3A || p == 0x2D) }()
                if boundary, let end = matchNetwork(t, i) {
                    result.append(Match(start: i, end: end, category: .network))
                    i = end
                    continue
                }
            }
            if isWord(b) {
                var j = i + 1
                while j < n, isWord(t[j]) { j += 1 }
                let length = j - i
                if length >= 2, length <= maxKeywordLength,
                   let key = pack(UnsafeBufferPointer(rebasing: t[i..<j])), let category = keywordTable[key] {
                    result.append(Match(start: i, end: j, category: category))
                }
                i = j
                continue
            }
            i += 1
        }
        return result
    }

    // MARK: Network addresses

    private static func matchNetwork(_ t: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
        matchMAC(t, i) ?? matchIPv6(t, i) ?? matchIPv4(t, i)
    }

    /// aa:bb:cc:dd:ee:ff or aa-bb-cc-dd-ee-ff (one separator throughout).
    private static func matchMAC(_ t: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
        let n = t.count
        guard i + 17 <= n else { return nil }
        let separator = t[i + 2]
        guard separator == 0x3A || separator == 0x2D else { return nil }
        for group in 0..<6 {
            let p = i + group * 3
            guard isHex(t[p]), isHex(t[p + 1]) else { return nil }
            if group < 5, t[p + 2] != separator { return nil }
        }
        let end = i + 17
        if end < n {
            let next = t[end]
            if isWord(next) { return nil }
            if next == 0x3A || next == 0x2D || next == 0x2E, end + 1 < n, isHex(t[end + 1]) { return nil }
        }
        return end
    }

    /// Dotted quad, each part 0–255 (1–3 digits). A following `:port` is left as plain text.
    private static func matchIPv4(_ t: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
        guard let end = parseIPv4(t, i, limit: t.count) else { return nil }
        if end < t.count {
            let next = t[end]
            if isWord(next) { return nil }
            if next == 0x2E, end + 1 < t.count, isDigit(t[end + 1]) { return nil }
        }
        return end
    }

    /// Parses a dotted quad starting at `i`; returns its end (no boundary check after it).
    private static func parseIPv4(_ t: UnsafeBufferPointer<UInt8>, _ i: Int, limit: Int) -> Int? {
        var p = i
        for part in 0..<4 {
            var digits = 0
            var value = 0
            while p < limit, isDigit(t[p]) {
                digits += 1
                if digits > 3 { return nil }
                value = value * 10 + Int(t[p] - 0x30)
                p += 1
            }
            guard digits > 0, value <= 255 else { return nil }
            if part < 3 {
                guard p < limit, t[p] == 0x2E else { return nil }
                p += 1
            }
        }
        return p
    }

    /// Longest run of hex digits, `:` and `.` (for an embedded IPv4 tail); one trailing `.`/`:` may be
    /// dropped (end of sentence). Needs ≥ 2 colons and a digit, to keep `a::b`/`::` out.
    private static func matchIPv6(_ t: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
        let n = t.count
        var j = i
        var colons = 0
        while j < n, isHex(t[j]) || t[j] == 0x3A || t[j] == 0x2E {
            if t[j] == 0x3A { colons += 1 }
            j += 1
        }
        guard colons >= 2 else { return nil }
        if j < n, isWord(t[j]) { return nil }
        if isValidIPv6(t, i, j) { return j }
        let last = t[j - 1]
        if last == 0x2E || last == 0x3A, j - 1 > i, isValidIPv6(t, i, j - 1) { return j - 1 }
        return nil
    }

    private static func isValidIPv6(_ t: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        var colons = 0
        var hasDigit = false
        var doubleColon: Int?
        var p = start
        while p < end {
            let b = t[p]
            if isDigit(b) { hasDigit = true }
            if b == 0x3A {
                colons += 1
                if p + 1 < end, t[p + 1] == 0x3A {
                    if doubleColon != nil { return false }
                    doubleColon = p
                }
            }
            p += 1
        }
        guard colons >= 2, hasDigit else { return false }
        if let dc = doubleColon {
            guard let left = groupCount(t, start, dc, allowIPv4Tail: false),
                  let right = groupCount(t, dc + 2, end, allowIPv4Tail: true) else { return false }
            return left + right <= 7
        }
        return groupCount(t, start, end, allowIPv4Tail: true) == 8
    }

    /// Groups of 1–4 hex digits separated by single colons (an IPv4 tail counts as two). Empty range → 0.
    private static func groupCount(_ t: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, allowIPv4Tail: Bool) -> Int? {
        if start == end { return 0 }
        var count = 0
        var groupStart = start
        while true {
            var groupEnd = groupStart
            while groupEnd < end, t[groupEnd] != 0x3A { groupEnd += 1 }
            let length = groupEnd - groupStart
            guard length > 0 else { return nil }
            var hasDot = false
            for q in groupStart..<groupEnd where t[q] == 0x2E { hasDot = true; break }
            if hasDot {
                guard allowIPv4Tail, groupEnd == end, parseIPv4(t, groupStart, limit: end) == end else { return nil }
                count += 2
            } else {
                guard length <= 4 else { return nil }
                for q in groupStart..<groupEnd where !isHex(t[q]) { return nil }
                count += 1
            }
            if groupEnd == end { return count }
            groupStart = groupEnd + 1
            if groupStart == end { return nil } // trailing single colon
        }
    }
}
