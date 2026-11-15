import SwiftUI
import AppCore

/// A credential change waiting for "Remove" / "Keep" because it makes saved secrets unneeded.
struct PendingCredentialChange {
    let change: CredentialChange
    let replaced: ReplacedSecrets
    /// The host's or identity's name, for the title.
    let name: String

    var title: String {
        let what: String
        switch (replaced.password, replaced.keyLink) {
        case (true, true): what = "the saved password and key link"
        case (true, false): what = "the saved password"
        case (false, _): what = "the key link"
        }
        return "Remove \(what) from \u{201C}\(name)\u{201D}?"
    }
}

extension PendingCredentialChange {
    var message: String {
        let base = "It\u{2019}s no longer needed with this login method. The key itself stays in Keychain."
        if case .passwordReference = change, replaced.keyLink {
            return base + "\n\nIf you keep the key, it\u{2019}s still used to log in \u{2014} the 1Password password is used only after the key is removed."
        }
        return base
    }
}

extension View {
    /// Asks whether to remove the secrets `pending` replaces: "Remove" (default), "Keep", or Cancel
    /// (Esc), which leaves the credential unchanged. `apply` gets the change and `removingReplaced`.
    func credentialChangeConfirmation(_ pending: Binding<PendingCredentialChange?>,
                                      apply: @escaping (CredentialChange, Bool) -> Void) -> some View {
        alert(pending.wrappedValue?.title ?? "",
              isPresented: Binding(get: { pending.wrappedValue != nil },
                                   set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { change in
            Button("Remove", role: .destructive) { apply(change.change, true) }
                .keyboardShortcut(.defaultAction)
            Button("Keep") { apply(change.change, false) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }
}
