import Foundation

/// Settings → Highlighting's preview line: sample text run through the same two highlighters a
/// terminal uses (custom rules, then built-in keywords), split into styled pieces.
public enum HighlightPreview {
    public struct Segment: Equatable, Sendable {
        public var text: String
        /// nil = the terminal's default foreground.
        public var color: RGBColor?
        public var isBold: Bool

        public init(text: String, color: RGBColor? = nil, isBold: Bool = false) {
            self.text = text
            self.color = color
            self.isBold = isBold
        }
    }

    /// `text` as a terminal would colour it, line breaks and other control characters shown as spaces.
    public static func segments(for text: String, keywords: KeywordHighlightSettings.Snapshot,
                                rules: CompiledHighlightRules) -> [Segment] {
        let clean = String(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) })
        let custom = CustomHighlighter(rules: rules)
        let keyword = KeywordHighlighter(settings: keywords)
        // A line break at the end, as a terminal line would have: the keyword highlighter emits a
        // word at the very end of a chunk plain (it might continue in the next chunk).
        var output = keyword.process(custom.process(ArraySlice(Array((clean + "\n").utf8)))[...])
        if output.last == 0x0A { output.removeLast() }
        return parse(output)
    }

    /// Splits highlighter output into segments, reading the SGR codes the highlighters insert
    /// (0, 1, 22, 39 and 38;2;R;G;B). The input has no other escape sequences.
    static func parse(_ bytes: [UInt8]) -> [Segment] {
        var segments: [Segment] = []
        var color: RGBColor?
        var bold = false
        var text: [UInt8] = []
        func flushText() {
            guard !text.isEmpty else { return }
            let piece = String(decoding: text, as: UTF8.self)
            if let last = segments.last, last.color == color, last.isBold == bold {
                segments[segments.count - 1].text += piece
            } else {
                segments.append(Segment(text: piece, color: color, isBold: bold))
            }
            text.removeAll()
        }
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                var j = i + 2
                while j < bytes.count, bytes[j] != 0x6D { j += 1 }
                flushText()
                let params = String(decoding: bytes[(i + 2)..<min(j, bytes.count)], as: UTF8.self)
                    .split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                var k = 0
                while k < params.count {
                    switch params[k] {
                    case 0: color = nil; bold = false
                    case 1: bold = true
                    case 22: bold = false
                    case 39: color = nil
                    case 38 where k + 4 < params.count && params[k + 1] == 2:
                        color = RGBColor(red: UInt8(clamping: params[k + 2]), green: UInt8(clamping: params[k + 3]),
                                         blue: UInt8(clamping: params[k + 4]))
                        k += 4
                    default: break
                    }
                    k += 1
                }
                i = j + 1
                continue
            }
            text.append(bytes[i])
            i += 1
        }
        flushText()
        return segments
    }
}
