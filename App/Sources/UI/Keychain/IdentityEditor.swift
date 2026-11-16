import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// The right-hand identity editor (same style as Host Details). It edits a local copy and saves
/// every change at once through `KeychainViewModel.update(_:)`. Create one per identity
/// (`.id(...)`); the identity is read once, on appear, not in `init`.
struct IdentityEditor: View {
    let model: KeychainViewModel
    let vault: LocalVault
    let identityID: UUID
    let onClose: () -> Void

    @State private var initial: Identity?

    var body: some View {
        ZStack {
            if let initial {
                IdentityEditorContent(model: model, vault: vault, initial: initial, onClose: onClose)
            } else {
                Theme.sidebarBackground
                    .frame(width: Theme.detailsPanelWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            if initial == nil {
                initial = vault.get(Identity.self, id: identityID)
            }
        }
    }
}

private struct IdentityEditorContent: View {
    let model: KeychainViewModel
    let vault: LocalVault
    let onClose: () -> Void

    /// The identity as edited. Every change is merged onto the stored record and saved.
    @State private var draft: Identity
    /// `draft.password` as typed; empty means no password.
    @State private var passwordText: String
    @State private var confirmDelete = false
    @State private var showError = false
    @State private var errorMessage = ""
    /// A credential change waiting for "Remove" / "Keep" (it makes saved secrets unneeded).
    @State private var pendingChange: PendingCredentialChange?

    init(model: KeychainViewModel, vault: LocalVault, initial: Identity, onClose: @escaping () -> Void) {
        self.model = model
        self.vault = vault
        self.onClose = onClose
        _draft = State(initialValue: initial)
        _passwordText = State(initialValue: initial.password ?? "")
    }

    /// Every key in the vault (unfiltered by the screen's search), by label.
    private var availableKeys: [SSHKey] {
        _ = vault.revision
        return vault.all(SSHKey.self).sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    generalCard
                    credentialsCard
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
        .onChange(of: passwordText) { _, text in
            draft.password = text.isEmpty ? nil : text
        }
        .onChange(of: draft) { _, edited in
            save(edited)
        }
        .onChange(of: vault.revision) { _, _ in
            dropMissingKey()
        }
        .onAppear {
            dropMissingKey()
        }
        .confirmationDialog("Delete this identity?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete identity", role: .destructive) { deleteIdentity() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .credentialChangeConfirmation($pendingChange) { change, removingReplaced in
            apply(change, removingReplaced: removingReplaced)
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Text("Identity Details")
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
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Text("Delete identity")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    // MARK: Cards

    private var generalCard: some View {
        DetailsCard {
            FieldColumn(title: "Label") {
                TextField("Label", text: $draft.label, prompt: Text("Name shown on the card"))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var credentialsCard: some View {
        DetailsCard {
            FieldColumn(title: "Username") {
                TextField("Username", text: $draft.username, prompt: Text("e.g. root"))
                    .textFieldStyle(.roundedBorder)
            }
            LoginMethodPicker(method: loginMethod)
            if draft.agentKey != nil {
                OnePasswordAgentKeyPicker(choice: $draft.agentKey)
            } else {
                passwordAndKeyFields
            }
        }
    }

    /// Switching to the agent asks whether to remove the saved password and key link (`request`).
    private var loginMethod: Binding<LoginMethod> {
        Binding(get: { LoginMethod(agentKey: draft.agentKey) },
                set: { method in
                    switch method {
                    case .passwordOrKey:
                        draft.agentKey = nil
                    case .onePasswordAgent:
                        if draft.agentKey == nil { request(.agent(AgentKeyChoice(publicKey: nil))) }
                    }
                })
    }

    /// Choosing a key asks whether to remove a saved password; "None" just unlinks the key.
    private var keySelection: Binding<UUID?> {
        Binding(get: { draft.sshKeyID },
                set: { keyID in
                    guard let keyID else {
                        draft.sshKeyID = nil
                        return
                    }
                    if keyID != draft.sshKeyID { request(.key(keyID)) }
                })
    }

    /// Applies `change` at once when it replaces nothing; otherwise asks first (Cancel changes nothing).
    private func request(_ change: CredentialChange) {
        // The view model reads the stored identity: save pending edits first.
        save(draft)
        let replaced = model.secretsReplaced(by: change, identityID: draft.id)
        if replaced.isEmpty {
            apply(change, removingReplaced: false)
        } else {
            let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = label.isEmpty ? draft.username : label
            pendingChange = PendingCredentialChange(change: change, replaced: replaced,
                                                    name: name.isEmpty ? "this identity" : name)
        }
    }

    /// Applies `change` through the view model, then takes over only the credential fields it saved.
    /// Label and username stay as typed (never reset by a login-method switch).
    private func apply(_ change: CredentialChange, removingReplaced: Bool) {
        model.apply(change, identityID: draft.id, removingReplaced: removingReplaced)
        guard let stored = vault.get(Identity.self, id: draft.id) else { return }
        draft.password = stored.password
        draft.sshKeyID = stored.sshKeyID
        draft.agentKey = stored.agentKey
        passwordText = stored.password ?? ""
    }

    @ViewBuilder
    private var passwordAndKeyFields: some View {
        FieldColumn(title: "Password") {
            OnePasswordPasswordField(title: "Password", text: $passwordText) { reference in
                request(.passwordReference(reference))
            }
        }
        FieldColumn(title: "Key") {
            Picker("Key", selection: keySelection) {
                Text("None").tag(UUID?.none)
                ForEach(availableKeys) { key in
                    Text(key.label.isEmpty ? "Untitled key" : key.label)
                        .tag(UUID?.some(key.id))
                }
            }
            .labelsHidden()
            if availableKeys.isEmpty {
                Text("No keys yet. Generate or import one with New.")
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

    private var usageSummary: String {
        _ = vault.revision
        return model.usageSummary(identityID: draft.id)
    }

    private var deleteMessage: String {
        let name = "\u{201C}\(draft.label)\u{201D}"
        switch model.usageCount(identityID: draft.id) {
        case 0:
            return "\(name) isn't used by any host. It will be removed from this vault."
        case 1:
            return "Used by 1 host. That host will no longer use \(name)."
        case let count:
            return "Used by \(count) hosts. Those hosts will no longer use \(name)."
        }
    }

    // MARK: Actions

    /// Saves synchronously, merged onto the stored identity; a deleted identity stays deleted.
    private func save(_ edited: Identity) {
        model.updateNow(edited) // merges agentKey too
    }

    /// Drops a key reference whose key was deleted, so the Picker never holds an invalid tag.
    private func dropMissingKey() {
        if let keyID = draft.sshKeyID, vault.get(SSHKey.self, id: keyID) == nil {
            draft.sshKeyID = nil
        }
    }

    private func deleteIdentity() {
        let id = draft.id
        Task {
            do {
                try await model.deleteIdentity(id: id)
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
