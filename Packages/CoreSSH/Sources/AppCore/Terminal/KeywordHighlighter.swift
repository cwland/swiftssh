import Foundation

/// Recolours keywords, IP addresses and MAC addresses in terminal output as it streams in.
///
/// Rules (v0.6.1 plan, Additions §2, plus the review fix round):
/// - Only text whose current foreground is the terminal default is recoloured (and not while SGR 7
///   inverse video is on); colours the program set are never overridden. The foreground/inverse state is
///   tracked the way SwiftTerm 1.99.3 tracks it: SGR (including 38/48/58 forms and its 24-parameter limit),
///   saved/restored cursor attributes (ESC 7/8, CSI s/u, ?1048, ?1049; one saved slot per screen), DECSTR
///   and RIS.
/// - The only change ever made to the stream is inserting `ESC[38;2;R;G;Bm` before a match and
///   `ESC[39m` (default foreground) after it. Every input byte is emitted, in order. Nothing is ever
///   inserted inside an escape sequence. The escape grammar follows SwiftTerm's parser: only OSC and APC
///   end on BEL; DCS, SOS and PM end on ST (ESC \ or 0x9C); DEL is ignored inside sequences; 8-bit C1
///   introducers are honoured outside ground.
/// - Off while the alternate screen is active (`CSI ? 1049/1047/47 h` … `l`), e.g. vim/htop/less.
/// - Matches are whole words, case-insensitive. Word characters are ASCII letters, digits, `_` and
///   every byte ≥ 0x80 (so nothing is matched glued to a non-ASCII letter, and insertions only ever
///   happen next to ASCII bytes — UTF-8 sequences are never split). A word interrupted by an escape
///   sequence (`err ESC[0m or`) is not a match.
///
/// Streaming (review ruling I3, "no typing lag"): text is never held back between calls — everything
/// `process` receives is returned by that call. A word cut by a chunk boundary is emitted plain (a missed
/// highlight, never a delay). A word followed by escape sequences is held only until the end of the same
/// chunk (at most `maxHeldBytes`). `flush()` therefore always returns [] and is kept for API stability.
///
/// Threading: not Sendable and not actor-isolated — one instance per tab, used from one thread or
/// actor at a time (create it where the output is processed). Settings arrive as a Sendable
/// `KeywordHighlightSettings.Snapshot`.
public final class KeywordHighlighter {
    /// Upper bound on bytes held back inside one `process` call (a word plus escapes right after it).
    public static let maxHeldBytes = 64

    public private(set) var settings: KeywordHighlightSettings.Snapshot
    /// True between `CSI ? 1049 h` (or 47/1047) and the matching `l`. Tracked even when disabled.
    public private(set) var isAlternateScreenActive = false

    private var openSequences: [[UInt8]] = []
    private static let closeSequence: [UInt8] = [0x1B, 0x5B, 0x33, 0x39, 0x6D] // ESC [ 3 9 m

    // Parser states, after SwiftTerm's EscapeSequenceParser (DCS entry/param/intermediate are one
    // "header" state, passthrough/ignore one "body" state; OSC and APC share one).
    private enum ParseState {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case oscString, sosPmString, dcsHeader, dcsBody
    }
    private var state = ParseState.ground

    // CSI being parsed, like SwiftTerm's `pars`/`collect`: params start as [0]; at most 24.
    private static let maximumParameterCount = 24
    private static let maximumParameterValue = Int(UInt16.max)
    private var csiParams: [Int] = [0]
    private var csiColonMask: UInt64 = 0
    private var csiCollect: [UInt8] = []
    private var csiLimitExceeded = false

    private struct Attributes: Equatable {
        var foregroundIsDefault = true
        var inverse = false
    }
    private var attributes = Attributes()
    /// Saved cursor attributes, one slot per screen (SwiftTerm keeps `savedAttr` per buffer).
    private var savedNormal = Attributes()
    private var savedAlternate = Attributes()
    /// DECLRMM (?69): while on, CSI s sets margins instead of saving the cursor.
    private var marginMode = false

    /// Bytes not yet emitted: `tokenLength` text bytes of a candidate word, then (if `heldEscape`)
    /// escape-sequence bytes that followed it. Always emptied before `process` returns.
    private var held: [UInt8] = []
    private var tokenLength = 0
    private var heldEscape = false
    /// Inside a run of token bytes that can't be matched (started mid-word, coloured, overflowed, or
    /// continuing from the previous chunk); passes straight through until the next break byte.
    private var passthroughToken = false

    /// `settings.isEnabled == false` makes the output byte-identical to the input (state is still
    /// tracked so turning it on later is correct).
    public init(settings: KeywordHighlightSettings.Snapshot = .default) {
        self.settings = settings
        held.reserveCapacity(Self.maxHeldBytes + 8)
        buildSequences()
    }

    /// Live settings change; keeps the terminal state (colours, alternate screen).
    public func update(settings: KeywordHighlightSettings.Snapshot) {
        self.settings = settings
        buildSequences()
    }

    /// Processes the next chunk of terminal output; returns the bytes to feed the terminal now — always
    /// all of them (plus any inserted colour codes).
    public func process(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 4 + 16)
        for byte in bytes { step(byte, &out) }
        if tokenLength > 0 {
            // The word may continue in the next chunk: emit it plain rather than wait (ruling I3).
            emitHeldRaw(&out)
            passthroughToken = true
        }
        return out
    }

    /// Nothing is ever held between calls, so this always returns []. Kept so callers may flush on idle.
    public func flush() -> [UInt8] { [] }

    // MARK: - Byte state machine

    private var canHighlight: Bool {
        settings.isEnabled && attributes.foregroundIsDefault && !attributes.inverse && !isAlternateScreenActive
    }

    @inline(__always)
    private func step(_ b: UInt8, _ out: inout [UInt8]) {
        if state == .ground {
            ground(b, &out)
            return
        }
        emitEscapeByte(b, &out)
        // "Anywhere" rules (SwiftTerm: ESC, SUB, EM and the C1 introducers); OSC/APC keep ≥ 0x80 as payload.
        switch b {
        case 0x1B:
            state = .escape
            return
        case 0x19, 0x1A:
            state = .ground
            return
        case 0x80...0x9F where state != .oscString:
            c1(b)
            return
        default: break
        }
        switch state {
        case .ground: break
        case .escape: escape(b)
        case .escapeIntermediate:
            switch b {
            case 0x30...0x7E: state = .ground
            case 0xA0...0xFF: state = .ground
            default: break // intermediates, C0, DEL
            }
        case .csiEntry, .csiParam, .csiIntermediate, .csiIgnore: csi(b)
        case .oscString:
            if b == 0x07 || b == 0x18 { state = .ground } // BEL / CAN end OSC and APC
        case .sosPmString:
            if b >= 0xA0 { state = .ground } // as SwiftTerm's table (error → ground); BEL/CAN/DEL ignored
        case .dcsHeader:
            switch b {
            case 0x40...0x7E: state = .dcsBody // hook
            case 0x3A: state = .dcsBody        // dcsIgnore: also runs to ST
            case 0xA0...0xFF: state = .ground
            default: break
            }
        case .dcsBody: break // ends only on ST / ESC / SUB / C1 (handled above)
        }
    }

    /// 8-bit C1 bytes outside ground and OSC/APC, as SwiftTerm's "anywhere" table entries.
    private func c1(_ b: UInt8) {
        switch b {
        case 0x9B: startCSI()
        case 0x9D, 0x9F: state = .oscString
        case 0x98, 0x9E: state = .sosPmString
        case 0x90: state = .dcsHeader
        default: state = .ground // other C1 controls execute; 0x9C (ST) ends strings
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

    private func escape(_ b: UInt8) {
        switch b {
        case 0x5B: startCSI()                           // [
        case 0x5D, 0x5F: state = .oscString             // ] _
        case 0x50: state = .dcsHeader                   // P
        case 0x58, 0x5E: state = .sosPmString           // X ^
        case 0x20...0x2F: state = .escapeIntermediate
        case 0x37:                                      // ESC 7 — DECSC
            saveCursor()
            state = .ground
        case 0x38:                                      // ESC 8 — DECRC
            restoreCursor()
            state = .ground
        case 0x63:                                      // ESC c — RIS
            attributes = Attributes()
            savedNormal = Attributes()
            savedAlternate = Attributes()
            isAlternateScreenActive = false
            marginMode = false
            state = .ground
        case 0x30...0x7E, 0xA0...0xFF: state = .ground
        default: break // C0 controls execute, DEL is ignored: the sequence goes on
        }
    }

    private func startCSI() {
        state = .csiEntry
        csiParams.removeAll(keepingCapacity: true)
        csiParams.append(0)
        csiColonMask = 0
        csiCollect.removeAll(keepingCapacity: true)
        csiLimitExceeded = false
    }

    private func csi(_ b: UInt8) {
        switch state {
        case .csiEntry, .csiParam:
            switch b {
            case 0x30...0x39: csiDigit(b); state = .csiParam
            case 0x3B: csiSeparator(colon: false); state = .csiParam
            case 0x3A:
                if state == .csiEntry { state = .ground } // SwiftTerm: no entry for ':' first → error
                else { csiSeparator(colon: true) }
            case 0x3C...0x3F:
                if state == .csiEntry { csiCollect.append(b); state = .csiParam } else { state = .csiIgnore }
            case 0x20...0x2F: csiCollect.append(b); state = .csiIntermediate
            case 0x40...0x7E: dispatchCSI(final: b); state = .ground
            case 0xA0...0xFF: state = .ground
            default: break // C0 executes, DEL ignored
            }
        case .csiIntermediate:
            switch b {
            case 0x20...0x2F: csiCollect.append(b)
            case 0x30...0x3F: state = .csiIgnore
            case 0x40...0x7E: dispatchCSI(final: b); state = .ground
            case 0xA0...0xFF: state = .ground
            default: break
            }
        case .csiIgnore:
            if (0x40...0x7E).contains(b) { state = .ground }
        default: break
        }
    }

    private func csiDigit(_ b: UInt8) {
        guard !csiLimitExceeded else { return }
        let digit = Int(b - 0x30)
        let index = csiParams.count - 1
        let current = csiParams[index]
        csiParams[index] = current > (Self.maximumParameterValue - digit) / 10
            ? Self.maximumParameterValue : current * 10 + digit
    }

    private func csiSeparator(colon: Bool) {
        if csiParams.count >= Self.maximumParameterCount {
            csiLimitExceeded = true
        } else if !csiLimitExceeded {
            if colon { csiColonMask |= UInt64(1) << UInt64(csiParams.count - 1) }
            csiParams.append(0)
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

    // MARK: - CSI dispatch (the subset that affects foreground, inverse and screen)

    private func dispatchCSI(final: UInt8) {
        guard !csiLimitExceeded else { return } // SwiftTerm drops the whole sequence
        switch final {
        case 0x6D: // m
            if csiCollect.isEmpty { applySGR() }
        case 0x68, 0x6C: // h / l
            guard csiCollect == [0x3F] else { return } // ?
            let set = final == 0x68
            for mode in csiParams {
                switch mode {
                case 1048: if set { saveCursor() } else { restoreCursor() }
                case 1049:
                    if set {
                        saveCursor()
                        isAlternateScreenActive = true
                    } else {
                        isAlternateScreenActive = false
                        restoreCursor()
                    }
                case 47, 1047: isAlternateScreenActive = set
                case 69: marginMode = set
                default: break
                }
            }
        case 0x73: // s — save cursor unless DECLRMM makes it DECSLRM
            if csiCollect.isEmpty, !marginMode { saveCursor() }
        case 0x75: // u — restore cursor (forms with a prefix are the kitty keyboard protocol)
            if csiCollect.isEmpty { restoreCursor() }
        case 0x70: // p — DECSTR (CSI ! p) soft reset
            if csiCollect == [0x21] {
                attributes = Attributes()
                if isAlternateScreenActive { savedAlternate = Attributes() } else { savedNormal = Attributes() }
                marginMode = false
            }
        default: break
        }
    }

    private func saveCursor() {
        if isAlternateScreenActive { savedAlternate = attributes } else { savedNormal = attributes }
    }

    private func restoreCursor() {
        attributes = isAlternateScreenActive ? savedAlternate : savedNormal
    }

    /// SwiftTerm's `cmdCharAttributes`, reduced to "is the foreground default" and inverse.
    private func applySGR() {
        let pars = csiParams
        let count = pars.count
        let mask = csiColonMask
        func colonAfter(_ index: Int) -> Bool {
            index >= 0 && index < 64 && mask & (UInt64(1) << UInt64(index)) != 0
        }
        /// (parsed a colour, parameters consumed) — as SwiftTerm's parseExtendedColor.
        func extendedColor(start: Int, usesColon: Bool) -> (Bool, Int) {
            guard start < count else { return (false, 0) }
            let kind = pars[start]
            if usesColon {
                var end = start
                while end < count - 1, colonAfter(end) { end += 1 }
                let length = end - start + 1
                switch kind {
                case 2: return (length >= 4, length)
                case 5: return (length >= 2, length)
                default: return (false, length)
                }
            }
            switch kind {
            case 2 where start + 3 < count: return (true, 4)
            case 5 where start + 1 < count: return (true, 2)
            default: return (false, 1)
            }
        }
        var i = 0
        while i < count {
            switch pars[i] {
            case 0: attributes = Attributes()
            case 4 where colonAfter(i) && i + 1 < count:
                i += 2
                continue
            case 7: attributes.inverse = true
            case 27: attributes.inverse = false
            case 30...37, 90...97: attributes.foregroundIsDefault = false
            case 39: attributes.foregroundIsDefault = true
            case 38, 48, 58:
                let code = pars[i]
                i += 1
                let (parsed, consumed) = extendedColor(start: i, usesColon: colonAfter(i - 1))
                i += max(consumed, 1)
                if code == 38, parsed { attributes.foregroundIsDefault = false }
                continue
            default: break
            }
            i += 1
        }
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
                if networkCanStart(t, i), let end = matchNetwork(t, i) {
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

    /// An address may start at the token start, or right after `:`/`-` when the word before that separator
    /// has a non-hex character (`ip:`, `src:`, `eth0-`) — so it can't be the middle of a longer address
    /// (`1.2.3.4:5.6.7.8`, `aa:bb:…:ff:00`, `1:2:…:9`). Never after `.` or a word byte.
    private static func networkCanStart(_ t: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let p = t[i - 1]
        guard p == 0x3A || p == 0x2D else { return false }
        var k = i - 2
        guard k >= 0, isWord(t[k]) else { return false }
        var hasNonHex = false
        while k >= 0, isWord(t[k]) {
            if !isHex(t[k]) { hasNonHex = true }
            k -= 1
        }
        return hasNonHex
    }

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
