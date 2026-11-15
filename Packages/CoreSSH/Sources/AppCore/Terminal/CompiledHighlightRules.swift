import Foundation
import CoreModels

/// The colours offered for a custom highlighting rule. Each reads on light and dark terminal
/// backgrounds: at least 3:1 contrast (WCAG 2) against white and against #1E1E1E.
public enum HighlightPalette {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var name: String
        public var color: RGBColor
        public var id: String { name }
    }

    public static let colors: [Entry] = [
        Entry(name: "Red", color: RGBColor(red: 0xE5, green: 0x48, blue: 0x4D)),
        Entry(name: "Orange", color: RGBColor(red: 0xD9, green: 0x73, blue: 0x0D)),
        Entry(name: "Gold", color: RGBColor(red: 0xB5, green: 0x89, blue: 0x00)),
        Entry(name: "Green", color: RGBColor(red: 0x2E, green: 0x9D, blue: 0x4F)),
        Entry(name: "Teal", color: RGBColor(red: 0x12, green: 0x98, blue: 0x8F)),
        Entry(name: "Blue", color: RGBColor(red: 0x34, green: 0x78, blue: 0xF6)),
        Entry(name: "Purple", color: RGBColor(red: 0x9B, green: 0x5D, blue: 0xE5)),
        Entry(name: "Pink", color: RGBColor(red: 0xE0, green: 0x46, blue: 0x8A)),
    ]

    /// The colour a new rule starts with, and the one used for an unparsable stored colour.
    public static var defaultColor: RGBColor { colors[0].color }

    /// The palette entry with exactly this colour, if any (else it is a custom colour).
    public static func entry(for color: RGBColor) -> Entry? {
        colors.first { $0.color == color }
    }
}

/// How a match is drawn.
public struct HighlightStyle: Equatable, Sendable {
    public var color: RGBColor
    public var isBold: Bool

    public init(color: RGBColor, isBold: Bool = false) {
        self.color = color
        self.isBold = isBold
    }
}

extension HighlightRule {
    /// The rule's colour; an unparsable value reads as the palette's first colour.
    public var rgbColor: RGBColor { RGBColor(hex: color) ?? HighlightPalette.defaultColor }

    /// Why the rule can't be used ("Enter a word or phrase.", or the regular expression error), or
    /// nil when it can. Disabled rules are checked too.
    public var validationError: String? {
        CompiledHighlightRules.compile(self).error
    }
}

/// Custom highlighting rules compiled for matching: built once per change of the list and shared
/// (immutable) by every terminal.
///
/// Matching (one line of text at a time, see `matches(in:)`):
/// - A word or phrase rule matches the text literally, as whole words: where the pattern starts
///   (ends) with a letter, digit or `_`, the text before (after) the match must not be one, so
///   `prod` matches `prod` and `prod-db` but not `production`. Case-insensitive unless "Match case".
/// - A regular-expression rule (ICU syntax, as NSRegularExpression) matches anywhere.
///   Case-insensitive unless "Match case". Empty matches are ignored.
/// - Disabled rules, empty patterns and invalid regular expressions are skipped (invalid ones are
///   listed in `errors`); nothing here throws or traps.
/// - Overlaps: the earlier rule in the list wins; a later rule's match that overlaps text an
///   earlier rule already claimed is dropped whole (not trimmed).
///
/// Guarding against slow regular expressions (catastrophic backtracking), in three layers:
/// 1. Regular-expression rules skip lines longer than `maxRegexLineLength` UTF-8 bytes (literal
///    rules, which are linear-time, apply to any length).
/// 2. Each regular expression gets at most `regexTimeLimit` per line: the match is stopped through
///    NSRegularExpression's progress callback and that line keeps the matches found so far.
/// 3. The caller's `MatchBudget` bounds the matching time for a whole chunk of output (all rules);
///    once it is spent, the rest of that chunk is not matched (passes through plain), so a flood of
///    output (`cat` of a big log) never stalls the terminal.
/// At most `maxMatchesPerLine` matches are kept per line.
public final class CompiledHighlightRules: @unchecked Sendable, Equatable {
    // @unchecked Sendable: immutable after init; NSRegularExpression is documented thread-safe.

    public static let maxRegexLineLength = 2048
    public static let regexTimeLimit: Duration = .milliseconds(5)
    public static let maxMatchesPerLine = 256

    /// One match: UTF-8 byte offsets into the line, and the winning rule's style.
    public struct Match: Equatable, Sendable {
        public var range: Range<Int>
        public var style: HighlightStyle
        /// Index into `rules` of the rule that matched.
        public var ruleIndex: Int
    }

    /// Time left for matching in one chunk of output (layer 3 above).
    public struct MatchBudget {
        public var deadline: ContinuousClock.Instant
        public init(deadline: ContinuousClock.Instant) { self.deadline = deadline }
        public static func starting(now: ContinuousClock.Instant = .now, allowance: Duration) -> MatchBudget {
            MatchBudget(deadline: now + allowance)
        }
        public var isSpent: Bool { ContinuousClock.now >= deadline }
    }

    struct Entry {
        var regex: NSRegularExpression
        var isRegularExpression: Bool
        var style: HighlightStyle
        var ruleIndex: Int
    }

    /// The list this was compiled from (all rules, enabled or not).
    public let rules: [HighlightRule]
    /// Rule id → why it is skipped (empty pattern, invalid regular expression). Disabled rules included.
    public let errors: [UUID: String]
    let entries: [Entry]

    public static let empty = CompiledHighlightRules(rules: [])

    public init(rules: [HighlightRule]) {
        self.rules = rules
        var errors: [UUID: String] = [:]
        var entries: [Entry] = []
        for (index, rule) in rules.enumerated() {
            let compiled = Self.compile(rule)
            if let error = compiled.error { errors[rule.id] = error }
            guard rule.isEnabled, let regex = compiled.regex else { continue }
            entries.append(Entry(regex: regex, isRegularExpression: rule.isRegularExpression,
                                 style: HighlightStyle(color: rule.rgbColor, isBold: rule.isBold), ruleIndex: index))
        }
        self.errors = errors
        self.entries = entries
    }

    /// No enabled, valid rule: matching finds nothing.
    public var isEmpty: Bool { entries.isEmpty }

    public static func == (lhs: CompiledHighlightRules, rhs: CompiledHighlightRules) -> Bool {
        lhs === rhs || lhs.rules == rhs.rules
    }

    // MARK: Compiling

    static func compile(_ rule: HighlightRule) -> (regex: NSRegularExpression?, error: String?) {
        let pattern = rule.pattern
        guard !pattern.isEmpty else {
            return (nil, rule.isRegularExpression ? "Enter a regular expression." : "Enter a word or phrase.")
        }
        var options: NSRegularExpression.Options = []
        if !rule.matchCase { options.insert(.caseInsensitive) }
        let source: String
        if rule.isRegularExpression {
            source = pattern
        } else {
            source = literalPattern(pattern)
        }
        do {
            return (try NSRegularExpression(pattern: source, options: options), nil)
        } catch {
            if rule.isRegularExpression {
                return (nil, "This regular expression isn\u{2019}t valid. Check for unbalanced brackets or a stray \\, ( or *.")
            }
            return (nil, "This text can\u{2019}t be matched.")
        }
    }

    private static let wordClass = "[\\p{L}\\p{N}\\p{M}_]"

    /// The literal pattern, escaped, with a whole-word guard on each end that is a word character.
    static func literalPattern(_ text: String) -> String {
        var source = NSRegularExpression.escapedPattern(for: text)
        if let first = text.first, isWordCharacter(first) { source = "(?<!\(wordClass))" + source }
        if let last = text.last, isWordCharacter(last) { source += "(?!\(wordClass))" }
        return source
    }

    static func isWordCharacter(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }

    // MARK: Matching

    /// Matches in one line of text (no line breaks expected), sorted by position and never
    /// overlapping. `budget` (optional) bounds regex time across calls; see the type's notes.
    public func matches(in line: String, budget: MatchBudget? = nil) -> [Match] {
        guard !entries.isEmpty, !line.isEmpty, !(budget?.isSpent ?? false) else { return [] }
        let utf8Count = line.utf8.count
        let utf16 = line.utf16
        let fullRange = NSRange(location: 0, length: utf16.count)
        let regexAllowed = utf8Count <= Self.maxRegexLineLength
        var claimed: [(range: NSRange, entry: Int)] = []

        for (entryIndex, entry) in entries.enumerated() {
            if claimed.count >= Self.maxMatchesPerLine { break }
            if entry.isRegularExpression, !regexAllowed { continue }
            if budget?.isSpent ?? false { break }
            let start = ContinuousClock.now
            let limit = entry.isRegularExpression ? Self.regexTimeLimit : nil
            entry.regex.enumerateMatches(in: line, options: limit == nil ? [] : [.reportProgress],
                                         range: fullRange) { result, _, stop in
                if let limit, ContinuousClock.now - start > limit {
                    stop.pointee = true
                }
                guard let range = result?.range, range.length > 0 else { return }
                if claimed.count >= Self.maxMatchesPerLine {
                    stop.pointee = true
                    return
                }
                let overlaps = claimed.contains { NSIntersectionRange($0.range, range).length > 0 }
                if !overlaps { claimed.append((range, entryIndex)) }
            }
        }
        guard !claimed.isEmpty else { return [] }
        claimed.sort { $0.range.location < $1.range.location }

        // UTF-16 offsets → UTF-8 offsets, in one forward walk.
        var result: [Match] = []
        result.reserveCapacity(claimed.count)
        var utf16Offset = 0
        var utf8Offset = 0
        var index = line.unicodeScalars.startIndex
        let scalars = line.unicodeScalars
        func advance(toUTF16 target: Int) -> Int {
            while utf16Offset < target, index < scalars.endIndex {
                let scalar = scalars[index]
                utf16Offset += scalar.utf16.count
                utf8Offset += scalar.utf8.count
                index = scalars.index(after: index)
            }
            return utf8Offset
        }
        for item in claimed {
            let lower = advance(toUTF16: item.range.location)
            let upper = advance(toUTF16: item.range.location + item.range.length)
            guard upper > lower else { continue }
            let entry = entries[item.entry]
            result.append(Match(range: lower..<upper, style: entry.style, ruleIndex: entry.ruleIndex))
        }
        return result
    }
}
