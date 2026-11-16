import Foundation

/// Why a request to the 1Password CLI (`op`) failed. Never carries a secret value: the details are
/// `op`'s own error text (stderr, never the stdout of `read`), which names references and items but not
/// their values; trimmed, at most 500 characters, control characters removed.
public enum OnePasswordError: Error, Equatable, Sendable, LocalizedError {
    /// `op` isn't installed where the app looks, or can't be run.
    case cliNotFound
    case appLocked(details: String?)
    /// The user dismissed the 1Password prompt, or the request was cancelled.
    case cancelled(details: String?)
    /// `op` can't reach the 1Password app: "Integrate with 1Password CLI" is off ("No accounts
    /// configured", a reset connection to the desktop app).
    case integrationOff(details: String?)
    /// macOS doesn't share 1Password's data (its group container) with this app: "Data shared by
    /// 1Password" is off in System Settings → Privacy & Security → Files & Folders. `op` says either
    /// "operation not permitted" on the group container, or "No accounts configured" while this app's
    /// own look into the container is refused (see `ProcessOnePasswordCLI`).
    case containerBlocked(details: String?)
    /// The 1Password app isn't running (nothing answers on its socket).
    case appNotRunning(details: String?)
    /// Nobody approved the request in time.
    case timedOut(details: String?)
    /// The vault, item or field doesn't exist; `op`'s explanation.
    case notFound(String)
    /// Any other failure; `op`'s explanation.
    case failed(String)

    /// `op`'s own text, for a "Details" disclosure; nil when there is none (always for `cliNotFound`).
    public var details: String? {
        switch self {
        case .cliNotFound: nil
        case .appLocked(let details), .cancelled(let details), .integrationOff(let details), .timedOut(let details),
             .containerBlocked(let details), .appNotRunning(let details):
            details
        case .notFound(let detail), .failed(let detail): detail
        }
    }

    /// For the disconnected banner and the setup checklist. Never includes `details`.
    public var message: String {
        switch self {
        case .cliNotFound:
            "The 1Password CLI (op) wasn't found. Install it from Settings \u{2192} 1Password."
        case .appLocked:
            "1Password is locked. Unlock it and try again."
        case .cancelled:
            "The 1Password request was cancelled."
        case .integrationOff:
            "The 1Password CLI isn't connected to the 1Password app. In 1Password, select your account at the top of the sidebar, then open Settings \u{2192} Developer and turn on \u{201C}Integrate with 1Password CLI\u{201D}. Keep 1Password in the menu bar."
        case .containerBlocked:
            "macOS is blocking SwiftSSH from 1Password\u{2019}s data. In System Settings \u{2192} Privacy & Security \u{2192} Files & Folders, turn on \u{201C}Data shared by 1Password\u{201D} for SwiftSSH, then quit and reopen SwiftSSH."
        case .appNotRunning:
            "1Password isn\u{2019}t running. Open 1Password, unlock it, and try again."
        case .timedOut:
            "1Password didn't get an answer in time. Approve the request in 1Password and try again."
        case .notFound(let detail):
            "1Password couldn't find it: \(detail)"
        case .failed(let detail):
            "1Password CLI failed: \(detail)"
        }
    }

    public var errorDescription: String? { message }

    /// Whether the fix is in Settings → 1Password (the setup checklist), not in the request itself.
    public var needsSetup: Bool {
        switch self {
        case .cliNotFound, .integrationOff, .appLocked, .containerBlocked, .appNotRunning: true
        case .cancelled, .timedOut, .notFound, .failed: false
        }
    }
}

/// An item as `op item list` shows it: no field values.
public struct OnePasswordItemSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// The vault's name (its ID when `op` gave no name).
    public let vault: String
    public let vaultID: String
    /// `op`'s category, e.g. "LOGIN", "SSH_KEY", "SERVER".
    public let category: String

    public init(id: String, title: String, vault: String, vaultID: String, category: String) {
        self.id = id
        self.title = title
        self.vault = vault
        self.vaultID = vaultID
        self.category = category
    }
}

/// A vault as `op vault list` shows it (no contents).
public struct OnePasswordVault: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A field of an item that can be referenced; the value itself is never fetched for it.
public struct OnePasswordField: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// `op://<vault>/<item>/<field>`.
    public let reference: String
    public let isSecret: Bool

    public init(id: String, label: String, reference: String, isSecret: Bool) {
        self.id = id
        self.label = label
        self.reference = reference
        self.isSecret = isSecret
    }

    /// What a field is picked for.
    public enum Purpose: Equatable, Sendable {
        /// Every standard field of the item.
        case any
        /// A password or key passphrase: only the "password" field of Login, Password, Server and
        /// Database items. Other items (an SSH key's "private key"/"public key" included) offer none;
        /// an SSH key belongs with the 1Password SSH agent instead.
        case password
    }

    /// The categories whose "password" field may be offered for `.password`.
    static let passwordCategories: Set<String> = ["LOGIN", "PASSWORD", "SERVER", "DATABASE"]

    /// The standard fields of an item of `category`, as references built locally. `op item get --format json`
    /// returns concealed values in plain text, so the picker never asks `op` for an item's fields. For
    /// `.any`, an SSH key offers "private key" and "public key"; anything else "password" and "username".
    /// For `.password`, see `Purpose.password`. The item is named by its ID; the vault by `vault` when that
    /// name may appear in a reference, otherwise by `vaultID`.
    public static func standardFields(itemID: String, vault: String, vaultID: String?, category: String?,
                                      purpose: Purpose = .any) -> [OnePasswordField] {
        let vaultPart = SecretReference.isSafeName(vault) ? vault : (vaultID ?? vault)
        let standard: [(label: String, secret: Bool)]
        switch purpose {
        case .any:
            standard = category == "SSH_KEY"
                ? [("private key", true), ("public key", false)]
                : [("password", true), ("username", false)]
        case .password:
            standard = category.map(passwordCategories.contains) == true ? [("password", true)] : []
        }
        return standard.map { field in
            OnePasswordField(id: field.label, label: field.label,
                             reference: "op://\(vaultPart)/\(itemID)/\(field.label)", isSecret: field.secret)
        }
    }
}

/// What the app asks of the 1Password CLI.
public protocol OnePasswordCLI: Sendable {
    /// The value of a secret reference (`op://…`). The value is never logged or put in an error.
    func read(reference: String) async throws(OnePasswordError) -> String
    func listItems() async throws(OnePasswordError) -> [OnePasswordItemSummary]
    /// The fields that can be referenced for an item (see `OnePasswordField.standardFields`); no values.
    func fields(itemID: String, vault: String) async throws(OnePasswordError) -> [OnePasswordField]
    /// A harmless call that proves `op` can talk to the 1Password app (`op vault list`).
    func check() async throws(OnePasswordError)
    /// The vaults `op` can see (`op vault list`): names and IDs only.
    func listVaults() async throws(OnePasswordError) -> [OnePasswordVault]
    /// Items of these `op` categories only (e.g. "SSH Key"), without field values.
    func listItems(categories: [String]) async throws(OnePasswordError) -> [OnePasswordItemSummary]
}

extension OnePasswordCLI {
    /// Clients that can't list vaults (test doubles) report it as a failure.
    public func listVaults() async throws(OnePasswordError) -> [OnePasswordVault] {
        throw .failed("Listing vaults isn't supported here.")
    }

    /// Falls back to every item, filtered here by `op`'s category IDs ("SSH Key" → "SSH_KEY").
    public func listItems(categories: [String]) async throws(OnePasswordError) -> [OnePasswordItemSummary] {
        let wanted = Set(categories.map(OnePasswordItemSummary.categoryID))
        return try await listItems().filter { wanted.contains($0.category) }
    }
}

extension OnePasswordItemSummary {
    /// `op`'s category ID for a category name: "SSH Key" → "SSH_KEY", "Login" → "LOGIN".
    public static func categoryID(_ name: String) -> String {
        name.uppercased().split(whereSeparator: { $0 == " " || $0 == "_" }).joined(separator: "_")
    }
}

public enum SecretReference {
    /// Whether a stored password or passphrase is a 1Password secret reference rather than the secret itself.
    public static func isReference(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("op://")
    }

    /// Whether `name` may appear as-is in a reference: ASCII letters and digits, `-`, `_`, `.` and spaces
    /// (1Password's secret reference syntax); anything else must be named by its ID.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".", " ": true
            default: false
            }
        }
    }
}
