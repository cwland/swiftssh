import Foundation

/// A snippet's script with its placeholders: `{{name}}` or `{{name:default}}`.
///
/// A name is letters, digits, `_` and `-`; spaces around the name and around the default are trimmed.
/// The default is everything after the first `:` (it may contain `:` and spaces, not `}}`). A
/// placeholder never spans lines. A `{{` without a valid placeholder up to the next `}}` on its line
/// stays literal text. Values are inserted as typed (no quoting).
public struct SnippetTemplate: Sendable, Equatable {
    public struct Placeholder: Sendable, Equatable, Identifiable {
        public let name: String
        public let defaultValue: String?
        public var id: String { name }

        public init(name: String, defaultValue: String?) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }

    /// Distinct placeholders, in first-appearance order. A name used more than once keeps the first
    /// default given.
    public let placeholders: [Placeholder]

    private enum Segment: Sendable, Equatable {
        case text(String)
        case placeholder(String)
    }

    private let segments: [Segment]

    public init(_ script: String) {
        var segments: [Segment] = []
        var order: [String] = []
        var defaults: [String: String] = [:]
        var literal = ""
        var index = script.startIndex
        while index < script.endIndex {
            if script[index...].hasPrefix("{{"), let (name, defaultValue, end) = Self.placeholder(in: script, at: index) {
                if !literal.isEmpty { segments.append(.text(literal)) }
                literal = ""
                segments.append(.placeholder(name))
                if !order.contains(name) { order.append(name) }
                if defaults[name] == nil, let defaultValue { defaults[name] = defaultValue }
                index = end
            } else {
                literal.append(script[index])
                index = script.index(after: index)
            }
        }
        if !literal.isEmpty { segments.append(.text(literal)) }
        self.segments = segments
        placeholders = order.map { Placeholder(name: $0, defaultValue: defaults[$0]) }
    }

    /// The placeholder starting with the `{{` at `start`: its name, default and the index after its `}}`.
    private static func placeholder(in script: String, at start: String.Index) -> (String, String?, String.Index)? {
        let contentStart = script.index(start, offsetBy: 2)
        guard let close = script.range(of: "}}", range: contentStart..<script.endIndex) else { return nil }
        let content = script[contentStart..<close.lowerBound]
        guard !content.contains(where: \.isNewline) else { return nil }
        let rawName: Substring
        var defaultValue: String?
        if let colon = content.firstIndex(of: ":") {
            rawName = content[..<colon]
            defaultValue = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        } else {
            rawName = content
        }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy(isNameCharacter) else { return nil }
        return (name, defaultValue, close.upperBound)
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || (c.isASCII && c.isNumber) || c == "_" || c == "-"
    }

    public var hasPlaceholders: Bool { !placeholders.isEmpty }

    /// The script with every placeholder replaced: the value given, else its default, else "".
    public func filled(with values: [String: String]) -> String {
        let defaults = Dictionary(placeholders.map { ($0.name, $0.defaultValue) }, uniquingKeysWith: { a, _ in a })
        var result = ""
        for segment in segments {
            switch segment {
            case .text(let text): result += text
            case .placeholder(let name): result += values[name] ?? defaults[name].flatMap { $0 } ?? ""
            }
        }
        return result
    }
}
