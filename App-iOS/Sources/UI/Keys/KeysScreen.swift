import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AppCore
import CoreModels
import SwiftSSHUI

/// SSH keys imported on this device, for hosts that sign in with a key from 1Password (iOS has no
/// 1Password SSH agent). Each key: name, type, fingerprint and the hosts pinned to it. Import by
/// pasting, from Files, or with "Open in SwiftSSH" from 1Password's share sheet; delete with a
/// confirmation. Keys stay in this device's Keychain, never synced.
struct KeysScreen: View {
    let vault: LocalVault
    @Environment(IOSEnvironment.self) private var environment
    @State private var form: KeyImportForm?
    @State private var showsImport = false
    @State private var showsFilePicker = false
    @State private var keyToDelete: ImportedKeyInfo?
    @State private var problem: String?

    /// Larger than any private key file.
    private static let maxFileSize = 64 * 1024

    var body: some View {
        let library = environment.importedKeys
        List {
            Section {
                ForEach(library.keys) { key in
                    KeyRow(key: key, hosts: hostNames(using: key))
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = key.publicKey
                            } label: {
                                Label("Copy Public Key", systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                keyToDelete = key
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                keyToDelete = key
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } footer: {
                Text("Hosts that sign in with a key from 1Password try these keys in turn. In 1Password, open the SSH key item and export it (or share it to SwiftSSH), then import it here. Keys stay in this device\u{2019}s Keychain and need \(DeviceAuthenticator.biometryName) to be used. RSA keys aren\u{2019}t supported yet.")
            }
        }
        .overlay {
            if library.keys.isEmpty {
                ContentUnavailableView {
                    Label("No Imported Keys", systemImage: "key")
                } description: {
                    Text("Import the SSH keys your 1Password hosts use. Export them from 1Password first.")
                } actions: {
                    importMenu
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                importMenu
            }
        }
        .sheet(isPresented: $showsImport, onDismiss: { form?.text = "" }) {
            if let form {
                ImportKeySheet(form: form)
            }
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): importFile(at: url, securityScoped: true)
            case .failure(let error): problem = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \u{201C}\(keyToDelete?.name ?? "")\u{201D}?", isPresented: deleteShown,
                            titleVisibility: .visible, presenting: keyToDelete) { key in
            Button("Delete Key", role: .destructive) {
                do {
                    try environment.importedKeys.delete(key.id)
                } catch {
                    problem = error.localizedDescription
                }
            }
        } message: { _ in
            Text("Hosts that use it can\u{2019}t sign in from this device until you import it again. 1Password and your Mac keep it.")
        }
        .alert("Can\u{2019}t Import", isPresented: problemShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .onAppear {
            if form == nil { form = KeyImportForm(library: environment.importedKeys) }
            takePendingFile()
        }
        .onChange(of: environment.navigation.pendingKeyFile) { takePendingFile() }
    }

    private var importMenu: some View {
        Menu {
            Button {
                form?.text = ""
                showsImport = true
            } label: {
                Label("Paste Key\u{2026}", systemImage: "doc.on.clipboard")
            }
            Button {
                showsFilePicker = true
            } label: {
                Label("Choose File\u{2026}", systemImage: "folder")
            }
        } label: {
            Label("Import Key", systemImage: "plus")
        }
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { keyToDelete != nil }, set: { if !$0 { keyToDelete = nil } })
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }

    private func hostNames(using key: ImportedKeyInfo) -> [String] {
        _ = vault.revision
        return environment.importedKeys.hosts(using: key, vault: vault).map { $0.label.isEmpty ? "Untitled host" : $0.label }
    }

    // MARK: Files

    /// A file opened in SwiftSSH ("Open in", share sheet) waiting in the navigation.
    private func takePendingFile() {
        guard let file = environment.navigation.takePendingKeyFile() else { return }
        load(file.data, name: file.name)
    }

    private func importFile(at url: URL, securityScoped: Bool) {
        let accessing = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maxFileSize else {
                problem = KeyImportForm.notTextMessage
                return
            }
            load(try Data(contentsOf: url), name: url.lastPathComponent)
        } catch {
            problem = "The file couldn\u{2019}t be read: \(error.localizedDescription)"
        }
    }

    private func load(_ data: Data, name: String) {
        if form == nil { form = KeyImportForm(library: environment.importedKeys) }
        guard let form else { return }
        form.text = ""
        if form.load(fileData: data, fileName: name) {
            showsImport = true
        } else {
            problem = form.errorMessage
        }
    }
}

/// One imported key.
private struct KeyRow: View {
    let key: ImportedKeyInfo
    let hosts: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolBadge(symbol: "key.fill", background: Theme.accent.opacity(0.15), foreground: Theme.accent)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(key.name)
                    .font(.body.weight(.medium))
                Text("\(key.type == .ed25519 ? "Ed25519" : "RSA") \u{00B7} \(key.fingerprint)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hosts.isEmpty ? "Not pinned to a host; offered to every 1Password host"
                                   : "Pinned by " + hosts.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Import a key: the private key (pasted or from a file), an optional name, and the passphrase when
/// the key is encrypted (used once, never saved).
struct ImportKeySheet: View {
    @Bindable var form: KeyImportForm
    @Environment(\.dismiss) private var dismiss
    @FocusState private var passphraseFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $form.text)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 140)
                        .accessibilityLabel("Private key")
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in form.text = strings.first ?? "" }
                    }
                } header: {
                    Text("Private key")
                } footer: {
                    Text("Starts with \u{201C}-----BEGIN OPENSSH PRIVATE KEY-----\u{201D} (or \u{201C}-----BEGIN PRIVATE KEY-----\u{201D}).")
                }
                Section {
                    TextField("Name (optional)", text: $form.name)
                } footer: {
                    Text("Blank uses the key\u{2019}s comment.")
                }
                if form.needsPassphrase {
                    Section {
                        SecureField("Passphrase", text: $form.passphrase)
                            .focused($passphraseFocused)
                            .submitLabel(.done)
                            .onSubmit(submit)
                    } header: {
                        Text("Passphrase")
                    } footer: {
                        Text("This key is protected by a passphrase. It is used once to import the key and isn\u{2019}t saved.")
                    }
                }
                if let error = form.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warningForeground)
                    }
                }
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: submit)
                        .disabled(!form.canImport)
                }
            }
            .onChange(of: form.needsPassphrase) { _, needs in
                if needs { passphraseFocused = true }
            }
        }
    }

    private func submit() {
        if form.submit() != nil { dismiss() }
    }
}
