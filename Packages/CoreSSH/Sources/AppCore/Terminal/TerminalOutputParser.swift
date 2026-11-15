import Foundation

/// The part of terminal-output parsing that output highlighters need: which bytes are printed text
/// (ground state) and which belong to escape sequences, and the attributes that decide whether text
/// may be recoloured (default foreground, inverse video, bold/faint, the alternate screen).
///
/// It follows SwiftTerm 1.99.3's parser: only OSC and APC end on BEL; DCS, SOS and PM end on ST
/// (ESC \ or 0x9C); DEL is ignored inside sequences; 8-bit C1 introducers are honoured outside
/// ground. SGR is tracked as SwiftTerm's `cmdCharAttributes` does (including 38/48/58 forms and
/// its 24-parameter limit), as are saved/restored cursor attributes (ESC 7/8, CSI s/u, ?1048,
/// ?1049; one saved slot per screen), DECSTR and RIS.
///
/// Shared by `KeywordHighlighter` and `CustomHighlighter`, so both agree on every byte.
struct TerminalOutputParser {
    /// The text attributes the highlighters care about.
    struct Attributes: Equatable {
        var foregroundIsDefault = true
        var inverse = false
        /// SGR 1 (bold) is on.
        var bold = false
        /// SGR 2 (faint) is on. SGR 22 clears both bold and faint.
        var faint = false
    }

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

    private(set) var attributes = Attributes()
    /// Saved cursor attributes, one slot per screen (SwiftTerm keeps `savedAttr` per buffer).
    private var savedNormal = Attributes()
    private var savedAlternate = Attributes()
    /// DECLRMM (?69): while on, CSI s sets margins instead of saving the cursor.
    private var marginMode = false

    /// True between `CSI ? 1049 h` (or 47/1047) and the matching `l`.
    private(set) var isAlternateScreenActive = false
    /// True between `CSI ? 2004 h` and `l`; reset by RIS.
    private(set) var isBracketedPasteActive = false

    init() {}

    /// The next byte is printed text unless it is ESC: no escape sequence is in progress.
    var isInGround: Bool { state == .ground }

    /// True when `b`, arriving next, is printed text (ground state, not ESC). Text bytes don't
    /// change the parser; pass every other byte to `consumeSequenceByte`.
    @inline(__always)
    func isTextByte(_ b: UInt8) -> Bool { state == .ground && b != 0x1B }

    /// Text in the default foreground, not inverse, on the normal screen: the only text a
    /// highlighter may recolour.
    var canRecolour: Bool {
        attributes.foregroundIsDefault && !attributes.inverse && !isAlternateScreenActive
    }

    /// Feeds one byte that is not a text byte (`isTextByte(b)` was false): ESC in ground, or any
    /// byte inside an escape sequence.
    mutating func consumeSequenceByte(_ b: UInt8) {
        if state == .ground {
            state = .escape // only ESC reaches here from ground
            return
        }
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
    private mutating func c1(_ b: UInt8) {
        switch b {
        case 0x9B: startCSI()
        case 0x9D, 0x9F: state = .oscString
        case 0x98, 0x9E: state = .sosPmString
        case 0x90: state = .dcsHeader
        default: state = .ground // other C1 controls execute; 0x9C (ST) ends strings
        }
    }

    private mutating func escape(_ b: UInt8) {
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
            isBracketedPasteActive = false
            marginMode = false
            state = .ground
        case 0x30...0x7E, 0xA0...0xFF: state = .ground
        default: break // C0 controls execute, DEL is ignored: the sequence goes on
        }
    }

    private mutating func startCSI() {
        state = .csiEntry
        csiParams.removeAll(keepingCapacity: true)
        csiParams.append(0)
        csiColonMask = 0
        csiCollect.removeAll(keepingCapacity: true)
        csiLimitExceeded = false
    }

    private mutating func csi(_ b: UInt8) {
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

    private mutating func csiDigit(_ b: UInt8) {
        guard !csiLimitExceeded else { return }
        let digit = Int(b - 0x30)
        let index = csiParams.count - 1
        let current = csiParams[index]
        csiParams[index] = current > (Self.maximumParameterValue - digit) / 10
            ? Self.maximumParameterValue : current * 10 + digit
    }

    private mutating func csiSeparator(colon: Bool) {
        if csiParams.count >= Self.maximumParameterCount {
            csiLimitExceeded = true
        } else if !csiLimitExceeded {
            if colon { csiColonMask |= UInt64(1) << UInt64(csiParams.count - 1) }
            csiParams.append(0)
        }
    }

    // MARK: - CSI dispatch (the subset that affects attributes and screen)

    private mutating func dispatchCSI(final: UInt8) {
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
                case 2004: isBracketedPasteActive = set
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

    private mutating func saveCursor() {
        if isAlternateScreenActive { savedAlternate = attributes } else { savedNormal = attributes }
    }

    private mutating func restoreCursor() {
        attributes = isAlternateScreenActive ? savedAlternate : savedNormal
    }

    /// SwiftTerm's `cmdCharAttributes`, reduced to foreground-is-default, inverse, bold and faint.
    private mutating func applySGR() {
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
            case 1: attributes.bold = true
            case 2: attributes.faint = true
            case 22:
                attributes.bold = false
                attributes.faint = false
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
}
