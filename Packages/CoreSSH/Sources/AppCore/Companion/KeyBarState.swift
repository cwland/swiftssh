import Foundation
import Observation

/// The key bar above the iPhone/iPad software keyboard: Esc, Tab, arrows and a few symbols, and the
/// sticky Ctrl and Alt modifiers.
///
/// A modifier is off, `once` (the next keystroke only) or `locked` (until tapped again): a tap turns
/// it from off to `once` and from `once` back off; a second tap within `doubleTapInterval` locks it;
/// a tap while locked turns it off. `transform(_:)` applies them to what the software keyboard
/// typed, and `bytes(for:applicationCursor:)` to the bar's own keys; both use up `once` modifiers.
/// A hardware keyboard's own Ctrl and Alt never pass through here.
@MainActor @Observable
public final class KeyBarState {
    public enum Modifier: Sendable, Hashable, CaseIterable {
        case ctrl, alt
    }

    public enum ModifierState: Sendable, Equatable {
        case off, once, locked
    }

    /// A key of the bar (the modifiers are separate).
    public enum Key: Sendable, Hashable {
        case escape, tab, up, down, left, right, home, end, pageUp, pageDown
        /// Typed as is (a symbol), with the modifiers applied.
        case text(String)

        /// The bar's keys in order; the view puts Ctrl and Alt after Esc.
        public static let bar: [Key] = [.escape, .tab, .left, .up, .down, .right,
                                        .text("|"), .text("/"), .text("-"), .text("~"), .text("_"),
                                        .home, .end, .pageUp, .pageDown]

        /// What the key shows.
        public var title: String {
            switch self {
            case .escape: "esc"
            case .tab: "tab"
            case .up: "\u{2191}"
            case .down: "\u{2193}"
            case .left: "\u{2190}"
            case .right: "\u{2192}"
            case .home: "home"
            case .end: "end"
            case .pageUp: "pg\u{2191}"
            case .pageDown: "pg\u{2193}"
            case .text(let text): text
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .escape: "Escape"
            case .tab: "Tab"
            case .up: "Up arrow"
            case .down: "Down arrow"
            case .left: "Left arrow"
            case .right: "Right arrow"
            case .home: "Home"
            case .end: "End"
            case .pageUp: "Page up"
            case .pageDown: "Page down"
            case .text("|"): "Vertical bar"
            case .text("/"): "Slash"
            case .text("-"): "Hyphen"
            case .text("~"): "Tilde"
            case .text("_"): "Underscore"
            case .text(let text): text
            }
        }
    }

    /// Two taps closer than this lock a modifier.
    public static let doubleTapInterval: TimeInterval = 0.35

    public private(set) var ctrl: ModifierState = .off
    public private(set) var alt: ModifierState = .off
    /// When each modifier was last turned on with a single tap (for the double tap).
    @ObservationIgnored private var onceSince: [Modifier: Date] = [:]

    public init() {}

    public func state(of modifier: Modifier) -> ModifierState {
        switch modifier {
        case .ctrl: ctrl
        case .alt: alt
        }
    }

    /// Whether a modifier applies to the next keystroke.
    public var isActive: Bool { ctrl != .off || alt != .off }

    /// The modifier's key was tapped at `date`.
    public func tap(_ modifier: Modifier, at date: Date = Date()) {
        let next: ModifierState
        switch state(of: modifier) {
        case .off:
            next = .once
            onceSince[modifier] = date
        case .once:
            if let since = onceSince[modifier], date.timeIntervalSince(since) <= Self.doubleTapInterval {
                next = .locked
            } else {
                next = .off
            }
            onceSince[modifier] = nil
        case .locked:
            next = .off
        }
        set(modifier, next)
    }

    /// Turns both modifiers off (a hardware keyboard was attached; the bar went away).
    public func releaseAll() {
        ctrl = .off
        alt = .off
        onceSince = [:]
    }

    /// What to send for one keystroke of the software keyboard: Ctrl turns letters and `@[\]^_`
    /// (and space, `?`) into control codes, Alt puts ESC in front. Uses up `once` modifiers.
    /// Unchanged (and nothing used up) when the input is empty.
    public func transform(_ input: [UInt8]) -> [UInt8] {
        guard !input.isEmpty else { return input }
        var output = input
        if ctrl != .off { output = output.map { Self.control($0) } }
        if alt != .off { output.insert(0x1B, at: 0) }
        useUpOnce()
        return output
    }

    /// What to send for one of the bar's keys. Arrows, Home and End follow the terminal's cursor key
    /// mode (`applicationCursor`: ESC O x instead of ESC [ x); with a modifier they use xterm's
    /// parameter form (`ESC [ 1 ; m x`, `ESC [ 5 ; m ~`). Uses up `once` modifiers.
    public func bytes(for key: Key, applicationCursor: Bool) -> [UInt8] {
        switch key {
        case .escape: return transform([0x1B])
        case .tab: return transform([0x09])
        case .text(let text): return transform(Array(text.utf8))
        case .up: return cursorKey("A", applicationCursor: applicationCursor)
        case .down: return cursorKey("B", applicationCursor: applicationCursor)
        case .right: return cursorKey("C", applicationCursor: applicationCursor)
        case .left: return cursorKey("D", applicationCursor: applicationCursor)
        case .home: return cursorKey("H", applicationCursor: applicationCursor)
        case .end: return cursorKey("F", applicationCursor: applicationCursor)
        case .pageUp: return tildeKey(5)
        case .pageDown: return tildeKey(6)
        }
    }

    // MARK: Internals

    private func set(_ modifier: Modifier, _ state: ModifierState) {
        switch modifier {
        case .ctrl: ctrl = state
        case .alt: alt = state
        }
    }

    private func useUpOnce() {
        if ctrl == .once { ctrl = .off; onceSince[.ctrl] = nil }
        if alt == .once { alt = .off; onceSince[.alt] = nil }
    }

    /// xterm's modifier parameter: 1 + 2 (Alt) + 4 (Ctrl); 1 = none.
    private var modifierParameter: Int {
        1 + (alt != .off ? 2 : 0) + (ctrl != .off ? 4 : 0)
    }

    private func cursorKey(_ final: Character, applicationCursor: Bool) -> [UInt8] {
        let parameter = modifierParameter
        useUpOnce()
        if parameter > 1 { return Array("\u{1B}[1;\(parameter)\(final)".utf8) }
        return Array("\u{1B}\(applicationCursor ? "O" : "[")\(final)".utf8)
    }

    private func tildeKey(_ code: Int) -> [UInt8] {
        let parameter = modifierParameter
        useUpOnce()
        if parameter > 1 { return Array("\u{1B}[\(code);\(parameter)~".utf8) }
        return Array("\u{1B}[\(code)~".utf8)
    }

    /// The control code for `byte`, or `byte` itself when it has none.
    private nonisolated static func control(_ byte: UInt8) -> UInt8 {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): byte - 0x60
        case UInt8(ascii: "@")...UInt8(ascii: "_"): byte - 0x40 // @, A–Z, [ \ ] ^ _
        case UInt8(ascii: " "): 0x00
        case UInt8(ascii: "?"): 0x7F
        default: byte
        }
    }
}
