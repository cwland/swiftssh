import Foundation

/// A snippet's script with its placeholders: `{{name}}` or `{{name:default}}`.
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

    /// Distinct placeholders, in first-appearance order.
    public let placeholders: [Placeholder]

    public init(_ script: String) {
        placeholders = [] // stub
    }

    public var hasPlaceholders: Bool { !placeholders.isEmpty }

    /// The script with every placeholder replaced: the value given, else its default, else "".
    public func filled(with values: [String: String]) -> String {
        "" // stub
    }
}
