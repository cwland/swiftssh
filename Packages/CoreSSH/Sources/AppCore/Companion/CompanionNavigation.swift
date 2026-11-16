import Foundation
import Observation
import CoreModels

/// The iPhone/iPad app's sections: the iPad sidebar, and the screens the iPhone pushes from Hosts.
public enum CompanionSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case hosts, snippets, knownHosts, keys, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hosts: "Hosts"
        case .snippets: "Snippets"
        case .knownHosts: "Known Hosts"
        case .keys: "Keys"
        case .settings: "Settings"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .hosts: "server.rack"
        case .snippets: "text.alignleft"
        case .knownHosts: "checkmark.shield"
        case .keys: "key"
        case .settings: "gearshape"
        }
    }
}

/// The numbers beside the iPad sidebar's sections: live records from the vault (as the Mac's
/// `SidebarCounts`) and the keys imported on this device. Settings has none.
public struct CompanionSidebarCounts: Equatable, Sendable {
    public let hosts: Int
    public let snippets: Int
    public let knownHosts: Int
    public let keys: Int

    @MainActor
    public init(vault: LocalVault, importedKeyCount: Int) {
        let counts = SidebarCounts(vault: vault)
        hosts = counts.hosts
        snippets = counts.snippets
        knownHosts = counts.knownHosts
        keys = importedKeyCount
    }

    public func count(for section: CompanionSection) -> Int? {
        switch section {
        case .hosts: hosts
        case .snippets: snippets
        case .knownHosts: knownHosts
        case .keys: keys
        case .settings: nil
        }
    }
}

/// A file opened in the iPhone/iPad app ("Open in SwiftSSH", the share sheet). With
/// `LSSupportsOpeningDocumentsInPlace` off, iOS hands the app its own copy: in `Documents/Inbox`, or
/// (current iOS versions) in `tmp/<bundle id>-Inbox`. That copy holds a private key, so the app deletes
/// it as soon as it is read.
public enum OpenedKeyFile {
    /// Whether `url` is the app's own copy of an opened file: inside `Documents/Inbox` or anywhere in
    /// the app's temporary directory. Symlinks are resolved on both sides (iOS hands out
    /// `/private/var/…` paths for a container that `FileManager` names `/var/…`), and `..` can't
    /// step out of those folders.
    public static func isAppOwnedCopy(_ url: URL, documentsDirectory: URL, temporaryDirectory: URL) -> Bool {
        guard url.isFileURL else { return false }
        let file = resolved(url)
        let inboxes = [resolved(documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)),
                       resolved(temporaryDirectory)]
        return inboxes.contains { folder in
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            return file.hasPrefix(prefix) && file.count > prefix.count
        }
    }

    /// The path with `..` removed and symlinks resolved. A file that no longer exists still resolves
    /// through its folder.
    private static func resolved(_ url: URL) -> String {
        let standard = url.standardizedFileURL
        let folder = standard.deletingLastPathComponent().resolvingSymlinksInPath()
        return folder.appendingPathComponent(standard.lastPathComponent).path
    }
}

/// Where the iPhone/iPad app is: the section shown (iPad sidebar selection; on iPhone the screen
/// pushed over Hosts, `phonePath`), and requests from keyboard shortcuts and other screens (search
/// the hosts, quick connect, import a key). Sessions are selected through `SessionManager`
/// (`selectedTabID` nil = these screens).
@MainActor @Observable
public final class CompanionNavigation {
    public var section: CompanionSection = .hosts
    /// The iPhone navigation stack over Hosts: empty, or the one section shown.
    public var phonePath: [CompanionSection] = []
    /// ⌘K: the quick connect sheet is up.
    public var isQuickConnectShown = false
    /// Bumped by ⌘F; the Hosts screen focuses its search field on each change.
    public private(set) var searchRequests = 0
    /// A key file opened in SwiftSSH ("Open in SwiftSSH", share sheet) waiting for the Keys screen's
    /// import form.
    public private(set) var pendingKeyFile: KeyFile?

    /// A file's contents and name. The contents are a private key: never logged or kept longer than
    /// the import takes.
    public struct KeyFile: Equatable, Sendable {
        public let data: Data
        public let name: String
    }

    public init() {}

    /// Shows `section` (on iPhone: pushes it over Hosts, or pops back to Hosts).
    public func show(_ section: CompanionSection) {
        self.section = section
        phonePath = section == .hosts ? [] : [section]
    }

    /// A key file was opened in the app: shows Keys, which takes the file into its import form.
    public func openKeyFile(data: Data, name: String) {
        pendingKeyFile = KeyFile(data: data, name: name)
        show(.keys)
    }

    /// The waiting key file, once.
    public func takePendingKeyFile() -> KeyFile? {
        defer { pendingKeyFile = nil }
        return pendingKeyFile
    }

    /// ⌘F: shows Hosts and asks it to focus its search field.
    public func requestSearch() {
        show(.hosts)
        searchRequests += 1
    }
}
