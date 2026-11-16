import SwiftUI
import AppKit
import AppCore
import CoreModels
import SwiftSSHUI

/// The right-hand key editor (same style as Host Details): label, type, read-only public key with
/// Copy, passphrase, and Delete with a usage warning. It edits a local copy and saves every change
/// at once through `KeychainViewModel.update(_:)`. Create one per key (`.id(...)`); the key is
/// read once, on appear, not in `init`.
struct KeyEditor: View {
    let model: KeychainViewModel
    let vault: LocalVault
    let keyID: UUID
    let onClose: () -> Void

    @State private var initial: SSHKey?

    var body: some View {
        ZStack {
            if let initial {
                KeyEditorContent(model: model, vault: vault, initial: initial, onClose: onClose)
            } else {
                Theme.sidebarBackground
                    .frame(width: Theme.detailsPanelWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            if initial == nil {
                initial = vault.get(SSHKey.self, id: keyID)
            }
        }
    }
}

private struct KeyEditorContent: View {
    let model: KeychainViewModel
    let vault: LocalVault
    let onClose: () -> Void

    /// The key as edited. Label and passphrase changes are merged onto the stored record and saved.
    @State private var draft: SSHKey
    /// `draft.passphrase` as typed; empty means no passphrase.
    @State private var passphraseText: String
    @State private var confirmDelete = false
    @State private var didCopy = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var showError = false
    @State private var errorMessage = ""

    init(model: KeychainViewModel, vault: LocalVault, initial: SSHKey, onClose: @escaping () -> Void) {
        self.model = model
        self.vault = vault
        self.onClose = onClose
        _draft = State(initialValue: initial)
        _passphraseText = State(initialValue: initial.passphrase ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    generalCard
                    publicKeyCard
                    passphraseCard
                    usageCard
                }
                .padding(16)
            }
            deleteButton
                .padding(16)
        }
        .frame(width: Theme.detailsPanelWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarBackground)
        .onChange(of: passphraseText) { _, text in
            draft.passphrase = text.isEmpty ? nil : text
        }
        .onChange(of: draft) { _, edited in
            save(edited)
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
        .confirmationDialog("Delete this key?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete key", role: .destructive) { deleteKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Text("Key Details")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                onClose()
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var deleteButton: some View {
        VStack(spacing: 6) {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Text("Delete key")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            if usageCount > 0 {
                Text(usageCount == 1
                     ? "Used by 1 host. Deleting it removes it from that host."
                     : "Used by \(usageCount) hosts. Deleting it removes it from those hosts.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Cards

    private var generalCard: some View {
        DetailsCard {
            FieldColumn(title: "Label") {
                TextField("Label", text: $draft.label, prompt: Text("Name shown on the card"))
                    .textFieldStyle(.roundedBorder)
            }
            FieldColumn(title: "Type") {
                Text(draft.keyType.displayName)
                    .font(.system(size: 13))
            }
        }
    }

    private var publicKeyCard: some View {
        DetailsCard {
            HStack {
                Text("Public key")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(didCopy ? "Copied" : "Copy") {
                    copyPublicKey()
                }
                .disabled(publicKey == nil)
                .help("Copy the public key to the clipboard")
            }
            if let publicKey {
                Text(publicKey)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No public key is stored for this key.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var passphraseCard: some View {
        DetailsCard {
            FieldColumn(title: "Passphrase") {
                RevealableSecureField(title: "Passphrase", text: $passphraseText)
                Text("Only needed if the private key is encrypted.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var usageCard: some View {
        DetailsCard {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text(usageSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Derived values

    private var publicKey: String? {
        model.publicKeyForCopy(sshKeyID: draft.id)
    }

    private var usageSummary: String {
        _ = vault.revision
        return model.usageSummary(sshKeyID: draft.id)
    }

    private var usageCount: Int {
        _ = vault.revision
        return model.usageCount(sshKeyID: draft.id)
    }

    private var deleteMessage: String {
        let name = "\u{201C}\(draft.label)\u{201D}"
        let hosts: String
        switch usageCount {
        case 0:
            hosts = "\(name) isn't used by any host. It will be removed from this vault."
        case 1:
            hosts = "Used by 1 host. That host will no longer use \(name)."
        case let count:
            hosts = "Used by \(count) hosts. Those hosts will no longer use \(name)."
        }
        let identityCount = vault.identitiesUsing(sshKeyID: draft.id).count
        switch identityCount {
        case 0:
            return hosts
        case 1:
            return hosts + " Also used by 1 identity; it'll lose the key."
        default:
            return hosts + " Also used by \(identityCount) identities; they'll lose the key."
        }
    }

    // MARK: Actions

    /// Applies the edited label and passphrase to the stored key and saves it.
    private func save(_ edited: SSHKey) {
        guard var current = vault.get(SSHKey.self, id: edited.id) else { return }
        current.label = edited.label
        current.passphrase = edited.passphrase
        model.update(current)
    }

    private func copyPublicKey() {
        guard let publicKey else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(publicKey, forType: .string)
        didCopy = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                didCopy = false
            }
        }
    }

    private func deleteKey() {
        let id = draft.id
        Task {
            do {
                try await model.deleteKey(id: id)
                onClose()
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: any Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

/// A `SecureField` with an eye button that switches it to a plain `TextField`.
struct RevealableSecureField: View {
    let title: String
    @Binding var text: String

    @State private var reveal = false

    var body: some View {
        HStack(spacing: 6) {
            if reveal {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                reveal.toggle()
            } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(reveal ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
        }
    }
}
