import Foundation

/// Which ⌘-clicked terminal links may open. Terminal output is untrusted (a remote program picks the
/// text, and an OSC 8 link can point anywhere), so only web, ssh and mail links open, in their default
/// apps; everything else (files, scripts, custom app schemes) is ignored.
public enum TerminalLinkFilter {
    public static let allowedSchemes: Set<String> = ["http", "https", "ssh", "mailto"]

    /// The URL to open for `link`, or nil to ignore the click. http, https and ssh need a host;
    /// mailto needs an address.
    public static func openableURL(_ link: String) -> URL? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        if scheme == "mailto" {
            let address = text.dropFirst("mailto:".count)
            return address.isEmpty ? nil : url
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
