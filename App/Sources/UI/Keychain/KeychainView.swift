import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import CoreModels
import SwiftSSHUI

/// The Keychain screen: search, "New" menu, identity and key cards, and a right-hand editor for
/// the selected identity or key. All behavior comes from `KeychainViewModel`.
struct KeychainView: View {
    @Bindable var model: KeychainViewModel
    let vault: LocalVault

    enum Selection: Hashable {
        case identity(UUID)
        case key(UUID)
    }

    @State private var selection: Selection?
    @State private var showGenerate = false
    @State private var showImport = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selection, selectionExists(selection) {
                Divider()
                editor(for: selection)
                    .id(selection)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selection)
        .background(Theme.contentBackground)
        .sheet(isPresented: $showGenerate) {
            GenerateKeySheet(model: model) { key in
                selection = .key(key.id)
            }
        }
        .sheet(isPresented: $showImport) {
            ImportKeySheet(model: model) { key in
                selection = .key(key.id)
            }
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: Layout

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar
            toolbar
            if model.identities.isEmpty && model.keys.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !model.identities.isEmpty {
                            identitiesSection
                        }
                        if !model.keys.isEmpty {
                            keysSection
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search identities and keys", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.searchFieldBackground)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("New identity") { createIdentity() }
                Button("Generate key…") { showGenerate = true }
                Button("Import key…") { showImport = true }
            } label: {
                Label("New", systemImage: "plus")
            }
            .fixedSize()

            Spacer(minLength: 0)
        }
    }

    private var columns: [GridItem] { Theme.cardGridColumns }

    private var identitiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Identities")
            LazyVGrid(columns: columns, spacing: Theme.cardSpacing) {
                ForEach(model.identities) { identity in
                    KeychainCardView(
                        symbol: "person.fill",
                        title: identity.label.isEmpty ? "Untitled identity" : identity.label,
                        subtitle: identity.username.isEmpty ? "No username" : identity.username,
                        usage: model.usageSummary(identityID: identity.id),
                        isSelected: selection == .identity(identity.id)
                    )
                    .onTapGesture {
                        selection = .identity(identity.id)
                    }
                }
            }
        }
    }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Keys")
            LazyVGrid(columns: columns, spacing: Theme.cardSpacing) {
                ForEach(model.keys) { key in
                    KeychainCardView(
                        symbol: "key.fill",
                        title: key.label.isEmpty ? "Untitled key" : key.label,
                        subtitle: key.keyType.displayName,
                        usage: model.usageSummary(sshKeyID: key.id),
                        isSelected: selection == .key(key.id)
                    )
                    .onTapGesture {
                        selection = .key(key.id)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "key")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No identities or keys yet — click New")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            } else {
                Text("No matching identities or keys")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editor panel

    /// Whether the selected record still exists (it may have been deleted).
    private func selectionExists(_ selection: Selection) -> Bool {
        _ = vault.revision
        switch selection {
        case .identity(let id):
            return vault.get(Identity.self, id: id) != nil
        case .key(let id):
            return vault.get(SSHKey.self, id: id) != nil
        }
    }

    @ViewBuilder
    private func editor(for selection: Selection) -> some View {
        switch selection {
        case .identity(let id):
            IdentityEditor(model: model, vault: vault, identityID: id) {
                self.selection = nil
            }
        case .key(let id):
            KeyEditor(model: model, vault: vault, keyID: id) {
                self.selection = nil
            }
        }
    }

    // MARK: Actions

    private func createIdentity() {
        Task {
            do {
                let identity = try await model.newIdentity()
                selection = .identity(identity.id)
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

/// An identity or key card: symbol badge, label, and one subtitle line with the detail and the
/// usage summary ("alice · Used by 3 hosts").
private struct KeychainCardView: View {
    let symbol: String
    let title: String
    let subtitle: String
    let usage: String
    let isSelected: Bool

    var body: some View {
        CardRow(title: title, subtitle: usage.isEmpty ? subtitle : "\(subtitle) \u{00B7} \(usage)",
                isSelected: isSelected) {
            SymbolBadge(symbol: symbol, background: Color(hex: "#5B6475"))
        }
    }
}

extension CoreModels.KeyType {
    /// Short name for cards and the key editor.
    var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .rsa: "RSA"
        }
    }
}

// MARK: - Generate sheet

/// Label + type (Ed25519 default, RSA-4096). RSA generation runs off the main actor and shows
/// a spinner; Generate is disabled meanwhile.
private struct GenerateKeySheet: View {
    let model: KeychainViewModel
    let onGenerated: (SSHKey) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = "Ed25519 key"
    @State private var keyType: CoreModels.KeyType = .ed25519
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Generate key")
                .font(.system(size: 17, weight: .semibold))

            FieldColumn(title: "Label") {
                TextField("Label", text: $label, prompt: Text("e.g. MacBook key"))
                    .textFieldStyle(.roundedBorder)
            }

            FieldColumn(title: "Type") {
                Picker("Type", selection: $keyType) {
                    Text("Ed25519").tag(CoreModels.KeyType.ed25519)
                    Text("RSA-4096").tag(CoreModels.KeyType.rsa)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isGenerating)
            }

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(keyType == .rsa ? "Generating RSA-4096 key… this can take a few seconds." : "Generating key…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isGenerating)
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isGenerating || trimmedLabel.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(isGenerating)
        .onChange(of: keyType) { oldType, newType in
            // Keep a default label in step with the type, but never overwrite a typed one.
            if label == Self.defaultLabel(for: oldType) {
                label = Self.defaultLabel(for: newType)
            }
        }
    }

    private static func defaultLabel(for type: CoreModels.KeyType) -> String {
        switch type {
        case .ed25519: "Ed25519 key"
        case .rsa: "RSA key"
        }
    }

    private func generate() {
        let newLabel = trimmedLabel
        let type = keyType
        guard !newLabel.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                let key = try await model.generateKey(label: newLabel, type: type)
                isGenerating = false
                onGenerated(key)
                dismiss()
            } catch {
                isGenerating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Import sheet

/// Label, "Choose file…" or a paste area, optional passphrase, and a public key field shown only
/// when the public key can't be derived from the private key. Errors are shown inline.
private struct ImportKeySheet: View {
    let model: KeychainViewModel
    let onImported: (SSHKey) -> Void

    /// Largest key file read from disk.
    private static let maxFileBytes = 64 * 1024

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var privateKeyText = ""
    @State private var passphrase = ""
    @State private var publicKeyText = ""
    @State private var showFileImporter = false
    /// Result of inspecting the pasted text: nil while the text is empty.
    @State private var inspection: Inspection?
    @State private var errorMessage: String?
    @State private var isImporting = false

    private enum Inspection: Equatable {
        case valid(derivedPublicKey: Bool, isEncrypted: Bool)
        case invalid(String)
    }

    private var isPrivateKeyEmpty: Bool {
        privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canImport: Bool {
        guard !isImporting, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .valid = inspection { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import key")
                .font(.system(size: 17, weight: .semibold))

            FieldColumn(title: "Label") {
                TextField("Label", text: $label, prompt: Text("e.g. id_ed25519"))
                    .textFieldStyle(.roundedBorder)
            }

            FieldColumn(title: "Private key") {
                HStack {
                    Button("Choose file…") { showFileImporter = true }
                    Text("or paste it below")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $privateKeyText)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(height: 140)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                    }
                if case .invalid(let message) = inspection {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .valid(_, let isEncrypted) = inspection, isEncrypted {
                    Text("This key is encrypted. Enter its passphrase below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            FieldColumn(title: "Passphrase (optional)") {
                RevealableSecureField(title: "Passphrase", text: $passphrase)
            }

            if case .valid(let derived, _) = inspection, !derived {
                FieldColumn(title: "Public key (optional)") {
                    TextField("Public key", text: $publicKeyText, prompt: Text("ssh-rsa AAAA… (from the .pub file)"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("The public key can't be read from this private key. Paste it to be able to copy it later.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { importKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data, .text, .item],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .onChange(of: privateKeyText) { _, text in
            inspect(text)
        }
    }

    // MARK: Actions

    private func inspect(_ text: String) {
        errorMessage = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            inspection = nil
            return
        }
        do {
            let imported = try SSHKeyImporter.inspect(privateKey: SSHKeyImporter.normalizePastedKey(text))
            inspection = .valid(derivedPublicKey: imported.publicKey != nil, isEncrypted: imported.isEncrypted)
        } catch {
            inspection = .invalid(error.localizedDescription)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], any Error>) {
        errorMessage = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                privateKeyText = try Self.readKeyFile(at: url)
                if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    label = url.lastPathComponent
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func importKey() {
        let trimmedLabel = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Undo smart-dash substitution on the armor lines before importing.
        let privateKey = SSHKeyImporter.normalizePastedKey(privateKeyText)
        let secret: String? = self.passphrase.isEmpty ? nil : self.passphrase
        let publicKey = publicKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        isImporting = true
        errorMessage = nil
        Task {
            do {
                let key = try await model.importKey(
                    label: trimmedLabel,
                    privateKey: privateKey,
                    passphrase: secret,
                    publicKey: publicKey.isEmpty ? nil : publicKey
                )
                isImporting = false
                onImported(key)
                dismiss()
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Reads at most 64 KB of UTF-8 text from a user-chosen file. Never logs the contents.
    private static func readKeyFile(at url: URL) throws -> String {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        guard data.count <= maxFileBytes else {
            throw KeyFileError.tooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeyFileError.notText
        }
        return text
    }

    private enum KeyFileError: Error, LocalizedError {
        case tooLarge
        case notText

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                "This file is larger than 64 KB, so it isn't an SSH key file."
            case .notText:
                "This file isn't a text file. Choose an OpenSSH or PEM private key."
            }
        }
    }
}
