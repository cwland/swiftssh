import Foundation

/// Which ⌘-clicked terminal links may open, and whether to ask first. Terminal output is untrusted:
/// a remote program picks the text, and an OSC 8 hyperlink can point somewhere other than the text
/// it shows. So only web and mail links open, in their default apps, and only when nothing in them
/// can fool the user or a handler:
/// - no control, format (Unicode Cf: bidi overrides, zero-width…) or whitespace characters anywhere;
/// - http/https need a host; neither host nor user may start with "-" (option injection into a
///   handler), checked on the percent-decoded value too;
/// - mailto needs an address (`user@domain`) that doesn't start with "-".
/// Everything else (ssh, files, scripts, custom app schemes) is ignored without a prompt.
public enum TerminalLinkFilter {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public enum Decision: Equatable, Sendable {
        /// Open at once.
        case open(URL)
        /// Show the full URL and open only if the user agrees.
        case confirm(URL)
        case ignore
    }

    /// `isExplicit` = an OSC 8 hyperlink; `visibleText` = the text it was drawn as, when known. A
    /// detected link is its own text, so it opens; an OSC 8 link opens without asking only when it
    /// shows exactly its target (surrounding whitespace aside).
    public static func decision(link: String, isExplicit: Bool, visibleText: String?) -> Decision {
        guard let url = openableURL(link) else { return .ignore }
        guard isExplicit else { return .open(url) }
        let shown = visibleText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return shown == link ? .open(url) : .confirm(url)
    }

    /// The URL to open for `link`, or nil to ignore it.
    public static func openableURL(_ link: String) -> URL? {
        guard !link.isEmpty, !link.unicodeScalars.contains(where: isForbidden),
              let components = URLComponents(string: link),
              let scheme = components.scheme?.lowercased(), allowedSchemes.contains(scheme),
              let url = components.url else { return nil }
        if scheme == "mailto" {
            let address = components.path
            guard let at = address.firstIndex(of: "@"), at != address.startIndex,
                  address.index(after: at) != address.endIndex, isSafeName(address) else { return nil }
            return url
        }
        guard let host = components.host, !host.isEmpty, isSafeName(host),
              isSafeName(components.percentEncodedHost ?? host) else { return nil }
        if let user = components.user, !isSafeName(user) { return nil }
        if let user = components.percentEncodedUser, !isSafeName(user) { return nil }
        return url
    }

    /// Doesn't start with "-" and (decoded) holds no forbidden character.
    private static func isSafeName(_ name: String) -> Bool {
        !name.hasPrefix("-") && !name.unicodeScalars.contains(where: isForbidden)
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator: return true
        default: return properties.isWhitespace
        }
    }
}

/// "Select text to copy": when a mouse-up should put the selection on the clipboard.
public enum SelectionCopyRule {
    /// Only a new, non-empty selection, and never while the program tracks the mouse (its clicks
    /// are the program's; a stale selection must not overwrite the clipboard on every click).
    /// `before` = the selection when the button went down, `after` = when it came up.
    public static func shouldCopy(before: String?, after: String?, programTracksMouse: Bool) -> Bool {
        guard !programTracksMouse, let after, !after.isEmpty else { return false }
        return after != before
    }
}
