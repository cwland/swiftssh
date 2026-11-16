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
/// - Text cut by a chunk boundary (`openStart`/`openEnd` in `matches(in:budget:openStart:openEnd:)`):
///   a word or phrase match whose whole-word guard touches the cut is dropped, because the word
///   may go on in the other chunk (`prod|uction`). A missed highlight, never a wrong one (as
///   `KeywordHighlighter` does). Regular expressions aren't affected.
///
/// Speed: the enabled word or phrase rules that share a case mode are compiled into one
/// alternation (`(rule1)|(rule2)|…`), so a line is scanned once for all of them, not once per rule;
/// the capture group says which rule matched. Where a scan hits, the later rules are tried at that
/// position too and the scan goes on from the next position, so every place each rule matches is
/// found and the result is exactly that of matching the rules one by one, in priority order.
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
        /// A word or phrase rule whose first (last) character is a word character: its match needs
        /// a non-word character, or the line's edge, before (after) it.
        var guardsStart = false
        var guardsEnd = false
        /// Matched through `literalGroups[group]` instead of on its own.
        var group: Int?
    }

    /// Enabled word or phrase rules of one case mode, as one alternation: capture group `k + 1`
    /// is `members[k]` (entry indices, in priority order).
    struct LiteralGroup {
        var regex: NSRegularExpression
        var members: [Int]
    }

    /// At most this many hits are examined per literal group and line (a line of 2,000 one-letter
    /// matches); `maxMatchesPerLine` caps what is kept anyway.
    static let maxLiteralHitsPerLine = 4 * maxMatchesPerLine

    /// The list this was compiled from (all rules, enabled or not).
    public let rules: [HighlightRule]
    /// Rule id → why it is skipped (empty pattern, invalid regular expression). Disabled rules included.
    public let errors: [UUID: String]
    let entries: [Entry]
    let literalGroups: [LiteralGroup]

    public static let empty = CompiledHighlightRules(rules: [])

    public init(rules: [HighlightRule]) {
        self.rules = rules
        var errors: [UUID: String] = [:]
        var entries: [Entry] = []
        for (index, rule) in rules.enumerated() {
            let compiled = Self.compile(rule)
            if let error = compiled.error { errors[rule.id] = error }
            guard rule.isEnabled, let regex = compiled.regex else { continue }
            var entry = Entry(regex: regex, isRegularExpression: rule.isRegularExpression,
                              style: HighlightStyle(color: rule.rgbColor, isBold: rule.isBold), ruleIndex: index)
            if !rule.isRegularExpression {
                entry.guardsStart = rule.pattern.first.map(Self.isWordCharacter) ?? false
                entry.guardsEnd = rule.pattern.last.map(Self.isWordCharacter) ?? false
            }
            entries.append(entry)
        }
        var groups: [LiteralGroup] = []
        for matchCase in [false, true] {
            let members = entries.indices.filter {
                !entries[$0].isRegularExpression && rules[entries[$0].ruleIndex].matchCase == matchCase
            }
            guard !members.isEmpty else { continue }
            let source = members.map { "(\(Self.literalPattern(rules[entries[$0].ruleIndex].pattern)))" }
                .joined(separator: "|")
            // Can't fail (each part compiled on its own); if it did, those rules match one by one.
            guard let regex = try? NSRegularExpression(pattern: source, options: matchCase ? [] : [.caseInsensitive])
            else { continue }
            for member in members { entries[member].group = groups.count }
            groups.append(LiteralGroup(regex: regex, members: members))
        }
        self.errors = errors
        self.entries = entries
        self.literalGroups = groups
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
    /// `openStart` (`openEnd`): the text may go on before (after) the line, in another chunk of
    /// output; word or phrase matches whose whole-word guard touches that edge are dropped.
    public func matches(in line: String, budget: MatchBudget? = nil, openStart: Bool = false,
                        openEnd: Bool = false) -> [Match] {
        guard !entries.isEmpty, !line.isEmpty, !(budget?.isSpent ?? false) else { return [] }
        let utf8Count = line.utf8.count
        let utf16 = line.utf16
        let fullRange = NSRange(location: 0, length: utf16.count)
        let regexAllowed = utf8Count <= Self.maxRegexLineLength
        var claimed: [(range: NSRange, entry: Int)] = []
        let literalMatches = literalGroups.map { ownMatches(of: $0, in: line, length: fullRange.length) }

        for (entryIndex, entry) in entries.enumerated() {
            if claimed.count >= Self.maxMatchesPerLine { break }
            if entry.isRegularExpression, !regexAllowed { continue }
            if budget?.isSpent ?? false { break }
            if let group = entry.group {
                let member = literalGroups[group].members.firstIndex(of: entryIndex) ?? 0
                for range in literalMatches[group][member] {
                    if claimed.count >= Self.maxMatchesPerLine { break }
                    let overlaps = claimed.contains { NSIntersectionRange($0.range, range).length > 0 }
                    if !overlaps { claimed.append((range, entryIndex)) }
                }
                continue
            }
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
            // Claimed first, dropped after: the text stays plain rather than going to a later rule.
            if openStart, entry.guardsStart, lower == 0 { continue }
            if openEnd, entry.guardsEnd, upper == utf8Count { continue }
            result.append(Match(range: lower..<upper, style: entry.style, ruleIndex: entry.ruleIndex))
        }
        return result
    }

    /// Each member's own matches in `line` (UTF-16 ranges), as matching that rule alone would find
    /// them: leftmost first, not overlapping each other. One scan of the group's alternation; at
    /// each hit the later members are tried at the same position (the alternation reports only
    /// the first that matches there), and the scan goes on from the next position so matches
    /// hidden inside a hit are found too.
    private func ownMatches(of group: LiteralGroup, in line: String, length: Int) -> [[NSRange]] {
        let count = group.members.count
        var hits = Array(repeating: [NSRange](), count: count)
        var location = 0
        var examined = 0
        while location < length, examined < Self.maxLiteralHitsPerLine,
              let hit = group.regex.firstMatch(in: line, options: [.withTransparentBounds],
                                               range: NSRange(location: location, length: length - location)) {
            examined += 1
            let position = hit.range.location
            guard let first = (0..<count).first(where: { hit.range(at: $0 + 1).location != NSNotFound }) else { break }
            if hit.range.length > 0 { hits[first].append(hit.range) }
            for later in (first + 1)..<count {
                let regex = entries[group.members[later]].regex
                if let other = regex.firstMatch(in: line, options: [.anchored, .withTransparentBounds],
                                                range: NSRange(location: position, length: length - position)),
                   other.range.length > 0 {
                    hits[later].append(other.range)
                }
            }
            location = position + 1
        }
        return hits.map { ranges in
            var own: [NSRange] = []
            var end = 0
            for range in ranges where range.location >= end {
                own.append(range)
                end = range.location + range.length
            }
            return own
        }
    }
}
