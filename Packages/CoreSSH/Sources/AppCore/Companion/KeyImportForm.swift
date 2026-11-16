import Foundation
import Observation

/// The Keys screen's import form on iPhone/iPad: the private key (pasted, or read from a file shared
/// from 1Password or Files), an optional name, and the passphrase, asked for only when the key is
/// encrypted. The passphrase never outlives an attempt that used it: it is cleared after a wrong one
/// and after a successful import (with the key text).
@MainActor @Observable
public final class KeyImportForm {
    /// The key as pasted or read. Changing it starts over: no passphrase asked, no error.
    public var text = "" {
        didSet {
            guard text != oldValue else { return }
            needsPassphrase = false
            passphrase = ""
            errorMessage = nil
        }
    }
    /// Blank = the key's comment (or `ImportedKeyLibrary.defaultName`).
    public var name = ""
    public var passphrase = ""
    /// The key is encrypted: the passphrase field shows.
    public private(set) var needsPassphrase = false
    public private(set) var errorMessage: String?

    public static let notTextMessage =
        "That file isn\u{2019}t a private key file. Export the SSH key from 1Password as a file, or copy it and paste it here."

    @ObservationIgnored private let library: ImportedKeyLibrary

    public init(library: ImportedKeyLibrary) {
        self.library = library
    }

    public var canImport: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!needsPassphrase || !passphrase.isEmpty)
    }

    /// Fills the form from a file: its text, and its name (without the extension) unless a name was
    /// typed. False, with `notTextMessage`, when the file isn't text.
    @discardableResult
    public func load(fileData: Data, fileName: String) -> Bool {
        guard let contents = String(data: fileData, encoding: .utf8) else {
            errorMessage = Self.notTextMessage
            return false
        }
        text = contents
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = (fileName as NSString).deletingPathExtension
            if !base.isEmpty, !base.hasPrefix("id_") { name = base }
        }
        return true
    }

    /// Imports the key. Nil when it wasn't: an encrypted key without its passphrase turns on
    /// `needsPassphrase`; anything else sets `errorMessage`.
    public func submit() -> ImportedKeyInfo? {
        guard canImport else { return nil }
        errorMessage = nil
        do {
            let info = try library.importKey(text: text, name: name, passphrase: needsPassphrase ? passphrase : nil)
            text = ""
            name = ""
            return info
        } catch ImportedKeyError.needsPassphrase {
            // The passphrase field appearing is the question.
            needsPassphrase = true
            passphrase = ""
            return nil
        } catch ImportedKeyError.wrongPassphrase {
            passphrase = ""
            errorMessage = ImportedKeyError.wrongPassphrase.errorDescription
            return nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }
}
