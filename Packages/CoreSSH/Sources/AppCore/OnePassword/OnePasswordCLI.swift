import Foundation

/// Why a request to the 1Password CLI (`op`) failed. Never carries a secret value: the details are
/// `op`'s own error text (stderr), which names references and items but not their values.
public enum OnePasswordError: Error, Equatable, Sendable, LocalizedError {
    /// `op` isn't installed where the app looks, or can't be run.
    case cliNotFound
    case appLocked
    /// The user dismissed the 1Password prompt, or the request was cancelled.
    case cancelled
    /// `op` can't reach the 1Password app ("Integrate with 1Password CLI" is off, or the app isn't running).
    case integrationOff
    /// Nobody approved the request in time.
    case timedOut
    /// The vault, item or field doesn't exist; `op`'s explanation.
    case notFound(String)
    /// Any other failure; `op`'s explanation.
    case failed(String)

    /// For the disconnected banner and the setup checklist.
    public var message: String {
        switch self {
        case .cliNotFound:
            "The 1Password CLI (op) wasn't found. Install it from Settings \u{2192} 1Password."
        case .appLocked:
            "1Password is locked. Unlock it and try again."
        case .cancelled:
            "The 1Password request was cancelled."
        case .integrationOff:
            "The 1Password CLI can't reach the 1Password app. Open 1Password, and in Settings \u{2192} Developer turn on \u{201C}Integrate with 1Password CLI\u{201D}."
        case .timedOut:
            "1Password didn't get an answer in time. Approve the request in 1Password and try again."
        case .notFound(let detail):
            "1Password couldn't find it: \(detail)"
        case .failed(let detail):
            "1Password CLI failed: \(detail)"
        }
    }

    public var errorDescription: String? { message }
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

    /// The standard fields of an item of `category`, as references built locally. `op item get --format json`
    /// returns concealed values in plain text, so the picker never asks `op` for an item's fields: an SSH key
    /// offers "private key" and "public key"; anything else "password" and "username". The item is named by
    /// its ID; the vault by `vault` when that name may appear in a reference, otherwise by `vaultID`.
    public static func standardFields(itemID: String, vault: String, vaultID: String?, category: String?) -> [OnePasswordField] {
        let vaultPart = SecretReference.isSafeName(vault) ? vault : (vaultID ?? vault)
        let standard: [(label: String, secret: Bool)] = category == "SSH_KEY"
            ? [("private key", true), ("public key", false)]
            : [("password", true), ("username", false)]
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
