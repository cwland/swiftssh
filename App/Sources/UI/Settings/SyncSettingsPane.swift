import SwiftUI
import Foundation
import AppCore
import CoreModels
import SyncCore

/// Settings → Sync: connect to Cory's sync server, create or join the encrypted vault, then
/// status, "Sync now", "Change passphrase…" and "Disconnect…". Which step shows follows
/// `SyncCoordinator.phase`. Secrets are typed only into secure fields and are never shown again.
struct SyncSettingsPane: View {
    /// nil until the vault is open.
    let sync: SyncCoordinator?
    let vault: LocalVault?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Keep hosts, identities, keys and snippets the same on your Macs through your own sync server. Everything is encrypted on this Mac before it\u{2019}s sent: the server never sees your data or your passphrase.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SyncSetupFlow(sync: sync, vault: vault)

                Text("Connection, 1Password and OS icon settings stay on this Mac. The server address is saved on this Mac; the API key and the vault key are kept in this Mac\u{2019}s Keychain.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// The sync steps in the order `SyncCoordinator.phase` calls for: connect (server address + API key),
/// create or join the vault, then status. Used by Settings → Sync and the welcome sheet.
struct SyncSetupFlow: View {
    /// nil until the vault is open.
    let sync: SyncCoordinator?
    let vault: LocalVault?

    var body: some View {
        if let sync {
            VStack(alignment: .leading, spacing: 16) {
                if let error = sync.lastError {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content(sync)
            }
        } else {
            SyncCard {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sync is available once the vault is open.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ sync: SyncCoordinator) -> some View {
        switch sync.phase {
        case .notConfigured:
            SyncConnectForm(sync: sync)
        case .needsVault(exists: false):
            SyncCreateVaultForm(sync: sync)
        case .needsVault(exists: true):
            SyncJoinVaultForm(sync: sync, hasLocalData: hasLocalData, isLocked: false)
        case .locked:
            SyncJoinVaultForm(sync: sync, hasLocalData: hasLocalData, isLocked: true)
        case .idle, .syncing, .offline, .failed:
            SyncStatusSection(sync: sync)
        }
    }

    /// Whether this Mac has hosts, identities or keys of its own (joining then asks merge or replace).
    private var hasLocalData: Bool {
        guard let vault else { return false }
        return !vault.all(SavedHost.self).isEmpty
            || !vault.all(Identity.self).isEmpty
            || !vault.all(SSHKey.self).isEmpty
    }
}

// MARK: - 1. Connect

/// Server address + API key, "Test connection" and "Connect".
private struct SyncConnectForm: View {
    let sync: SyncCoordinator

    @State private var serverText = ""
    @State private var apiKey = ""
    @State private var test: TestState = .idle
    @State private var isConnecting = false
    @State private var connectError: String?

    private enum TestState: Equatable {
        case idle, running
        case connected(vaultExists: Bool)
        case failed(String)
    }

    var body: some View {
        SyncCard(title: "Connect to your sync server",
                 subtitle: "The address of the sync server behind your reverse proxy, and one of the API keys in its SYNC_API_KEYS.") {
            SyncField("Server address") {
                TextField("Server address", text: $serverText, prompt: Text("https://your-proxy/sync"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
            }
            SyncField("API key") {
                SecureField("API key", text: $apiKey, prompt: Text("API key"))
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button("Test connection", action: runTest)
                    .disabled(!hasInput || test == .running || isConnecting)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasInput || test == .running || isConnecting)
                if isConnecting {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 4)

            testResult
            if let connectError {
                SyncErrorText(connectError)
            }
        }
        .onChange(of: serverText) { _, _ in resetResults() }
        .onChange(of: apiKey) { _, _ in resetResults() }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .connected(let vaultExists):
            Label(vaultExists ? "Connected \u{2014} a vault exists" : "Connected \u{2014} no vault yet",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed(let message):
            SyncErrorText(message)
        }
    }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedServer: String { serverText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasInput: Bool { !trimmedServer.isEmpty && !trimmedKey.isEmpty }

    private func resetResults() {
        if test != .running { test = .idle }
        connectError = nil
    }

    private func runTest() {
        connectError = nil
        let url: URL
        switch SyncCoordinator.validateServerURL(trimmedServer) {
        case .success(let valid): url = valid
        case .failure(let error):
            test = .failed(error.message)
            return
        }
        test = .running
        let key = trimmedKey
        Task {
            switch await sync.testConnection(serverURL: url, apiKey: key) {
            case .success(let vaultExists): test = .connected(vaultExists: vaultExists)
            case .failure(let error): test = .failed(error.message)
            }
        }
    }

    private func connect() {
        test = .idle
        connectError = nil
        let url: URL
        switch SyncCoordinator.validateServerURL(trimmedServer) {
        case .success(let valid): url = valid
        case .failure(let error):
            connectError = error.message
            return
        }
        isConnecting = true
        let key = trimmedKey
        Task {
            do throws(SyncSetupError) {
                // On success the phase moves on and this form goes away.
                try await sync.connect(serverURL: url, apiKey: key)
            } catch {
                connectError = error.message
            }
            isConnecting = false
        }
    }
}

// MARK: - 2a. Create the vault

/// The first Mac: choose the sync passphrase and create the vault.
private struct SyncCreateVaultForm: View {
    let sync: SyncCoordinator

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        SyncCard(title: "Set up sync",
                 subtitle: "There\u{2019}s no vault on the server yet. Choose a sync passphrase: it encrypts everything this Mac uploads. You\u{2019}ll enter it once on each other Mac.") {
            SyncField("Sync passphrase") {
                SecureField("Sync passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
            }
            SyncField("Confirm passphrase") {
                SecureField("Confirm passphrase", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
            }
            SyncNote("At least 12 characters. If you lose it, synced data can\u{2019}t be decrypted \u{2014} each Mac keeps its own copy.")
            if let problem = visibleProblem {
                SyncErrorText(problem)
            }

            HStack(spacing: 8) {
                Button("Create vault", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Creating the vault and uploading this Mac\u{2019}s data\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)

            if let errorMessage {
                SyncErrorText(errorMessage)
            }
            SyncServerFooter(sync: sync, isDisabled: isWorking)
        }
        .onChange(of: passphrase) { _, _ in errorMessage = nil }
    }

    /// Shown once something is typed: too short, then a mismatch.
    private var visibleProblem: String? {
        guard !passphrase.isEmpty else { return nil }
        if let problem = SyncCoordinator.passphraseProblem(passphrase) { return problem }
        if !confirmation.isEmpty && confirmation != passphrase { return "The passphrases don\u{2019}t match." }
        return nil
    }

    private var canCreate: Bool {
        !isWorking && SyncCoordinator.passphraseProblem(passphrase) == nil && confirmation == passphrase
    }

    private func create() {
        guard canCreate else { return }
        isWorking = true
        errorMessage = nil
        let chosen = passphrase
        Task {
            do throws(SyncSetupError) {
                try await sync.createVault(passphrase: chosen)
                passphrase = ""
                confirmation = ""
            } catch {
                errorMessage = error.message
            }
            isWorking = false
        }
    }
}

// MARK: - 2b. Join the vault

/// Another Mac (or this Mac without its vault key): enter the passphrase; with local data, choose
/// merge or replace.
private struct SyncJoinVaultForm: View {
    let sync: SyncCoordinator
    let hasLocalData: Bool
    /// Connected before, but this Mac has no vault key (e.g. its Keychain item is gone).
    let isLocked: Bool

    @State private var passphrase = ""
    @State private var mode: Choice = .merge
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isConfirmingReplace = false

    private enum Choice: CaseIterable {
        case merge, replace

        var title: String {
            switch self {
            case .merge: "Merge with this Mac\u{2019}s data (duplicates are matched up)"
            case .replace: "Replace this Mac\u{2019}s data with the vault\u{2019}s"
            }
        }

        var detail: String {
            switch self {
            case .merge: "Hosts with the same address, port and username, identities with the same label and username, and keys with the same public key become one. Everything else is uploaded."
            case .replace: "Everything synced on this Mac (hosts, groups, identities, keys, snippets, known hosts, logs and history) is removed and replaced with the vault\u{2019}s."
            }
        }

        var joinMode: JoinMode {
            switch self {
            case .merge: .merge
            case .replace: .replace
            }
        }
    }

    var body: some View {
        SyncCard(title: "Join this vault", subtitle: subtitle) {
            SyncField("Sync passphrase") {
                SecureField("Sync passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(requestJoin)
            }

            if hasLocalData {
                Text("This Mac already has hosts, identities or keys")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Choice.allCases, id: \.self) { choice in
                        SyncChoiceRow(title: choice.title, detail: choice.detail,
                                      isSelected: mode == choice) {
                            mode = choice
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("This Mac's data")
            }

            HStack(spacing: 8) {
                Button("Join", action: requestJoin)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty || isWorking)
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Unlocking the vault and syncing\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)

            if let errorMessage {
                SyncErrorText(errorMessage)
            }
            SyncServerFooter(sync: sync, isDisabled: isWorking)
        }
        .onChange(of: passphrase) { _, _ in errorMessage = nil }
        .alert("Replace this Mac\u{2019}s data?", isPresented: $isConfirmingReplace) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) { join(.replace) }
        } message: {
            Text("This removes everything synced on this Mac \u{2014} hosts, groups, identities, keys, snippets, known hosts, logs and history \u{2014} and replaces it with the vault\u{2019}s. Items that are only on this Mac are lost.")
        }
    }

    private var subtitle: String {
        isLocked
            ? "This Mac is connected to the sync server but doesn\u{2019}t have the vault key. Enter the sync passphrase you chose when the vault was created."
            : "The server already has a vault. Enter the sync passphrase you chose on your other Mac."
    }

    private func requestJoin() {
        guard !passphrase.isEmpty, !isWorking else { return }
        let choice: Choice = hasLocalData ? mode : .merge
        if choice == .replace {
            isConfirmingReplace = true
        } else {
            join(choice)
        }
    }

    private func join(_ choice: Choice) {
        isWorking = true
        errorMessage = nil
        let entered = passphrase
        Task {
            do throws(SyncSetupError) {
                try await sync.joinVault(passphrase: entered, mode: choice.joinMode)
                passphrase = ""
            } catch {
                errorMessage = error.message
            }
            isWorking = false
        }
    }
}

// MARK: - 3. Connected

/// Status, "Sync now", the server address, "Change passphrase…" and "Disconnect…".
private struct SyncStatusSection: View {
    let sync: SyncCoordinator

    @State private var isChangingPassphrase = false
    @State private var isConfirmingDisconnect = false
    @State private var passphraseChanged = false
    @State private var isUpdatingKey = false
    @State private var keyUpdated = false

    /// The server rejected this Mac's API key (the coordinator's `.failed` message for it).
    private var isKeyRejected: Bool {
        if case .failed(let message) = sync.phase {
            return message == SyncSetupError.unauthorized.message
        }
        return false
    }

    var body: some View {
        SyncCard {
            SyncStatusLine(sync: sync, fontSize: Theme.cardTitleFontSize)
            if isKeyRejected {
                SyncNote("The API key saved on this Mac is no longer accepted \u{2014} it may have been revoked or replaced in the server\u{2019}s SYNC_API_KEYS. Enter a current key to resume syncing.")
                Button("Update API key\u{2026}") {
                    keyUpdated = false
                    isUpdatingKey = true
                }
                .buttonStyle(.borderedProminent)
            }
            if let report = sync.lastReport {
                Text("Last sync: \(SyncTime.reportText(report))")
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Sync now") {
                    Task { await sync.syncNow() }
                }
                .disabled(!sync.phase.canSyncNow)
            }
            .padding(.top, 4)
        }

        SyncCard(title: "Server") {
            Text(sync.serverURL?.absoluteString ?? "\u{2014}")
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Button("Update API key\u{2026}") {
                    keyUpdated = false
                    isUpdatingKey = true
                }
                Button("Change passphrase\u{2026}") {
                    passphraseChanged = false
                    isChangingPassphrase = true
                }
                Button("Disconnect\u{2026}") {
                    isConfirmingDisconnect = true
                }
            }
            .padding(.top, 4)
            if keyUpdated {
                Label("API key updated.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
            if passphraseChanged {
                Label("Sync passphrase changed. Your other Macs keep syncing; use the new passphrase when you set up another Mac.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $isUpdatingKey) {
            UpdateAPIKeySheet(sync: sync) {
                keyUpdated = true
            }
        }
        .sheet(isPresented: $isChangingPassphrase) {
            ChangePassphraseSheet(sync: sync) {
                passphraseChanged = true
            }
        }
        .alert("Disconnect this Mac from sync?", isPresented: $isConfirmingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { sync.disconnect() }
        } message: {
            Text("This Mac stops syncing. Your data on this Mac is kept.")
        }
    }
}

/// A new API key for the same server (after the old one was revoked or replaced).
private struct UpdateAPIKeySheet: View {
    let sync: SyncCoordinator
    let onUpdated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update API key")
                .font(.system(size: 17, weight: .semibold))
            Text("Enter one of the keys in the server\u{2019}s SYNC_API_KEYS. The key is checked against the server, then saved in this Mac\u{2019}s Keychain. Your sync passphrase and data are not affected.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SyncField("API key") {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(update)
            }
            if let errorMessage {
                SyncErrorText(errorMessage)
            }

            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Update", action: update)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canUpdate)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(isWorking)
        .onChange(of: apiKey) { _, _ in errorMessage = nil }
    }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canUpdate: Bool { !isWorking && !trimmedKey.isEmpty }

    private func update() {
        guard canUpdate else { return }
        isWorking = true
        errorMessage = nil
        let key = trimmedKey
        Task {
            do throws(SyncSetupError) {
                try await sync.updateAPIKey(key)
                isWorking = false
                onUpdated()
                dismiss()
            } catch {
                errorMessage = error.message
                isWorking = false
            }
        }
    }
}

/// Old passphrase, new passphrase and confirmation; re-wraps the vault key on the server.
private struct ChangePassphraseSheet: View {
    let sync: SyncCoordinator
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var oldPassphrase = ""
    @State private var newPassphrase = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change sync passphrase")
                .font(.system(size: 17, weight: .semibold))
            Text("Your other Macs keep syncing without the new passphrase. Use it when you set up another Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SyncField("Current passphrase") {
                SecureField("Current passphrase", text: $oldPassphrase)
                    .textFieldStyle(.roundedBorder)
            }
            SyncField("New passphrase") {
                SecureField("New passphrase", text: $newPassphrase)
                    .textFieldStyle(.roundedBorder)
            }
            SyncField("Confirm new passphrase") {
                SecureField("Confirm new passphrase", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(change)
            }
            SyncNote("At least 12 characters. If you lose it, synced data can\u{2019}t be decrypted \u{2014} each Mac keeps its own copy.")
            if let problem = visibleProblem {
                SyncErrorText(problem)
            }
            if let errorMessage {
                SyncErrorText(errorMessage)
            }

            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Change Passphrase", action: change)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canChange)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(isWorking)
        .onChange(of: oldPassphrase) { _, _ in errorMessage = nil }
    }

    private var visibleProblem: String? {
        guard !newPassphrase.isEmpty else { return nil }
        if let problem = SyncCoordinator.passphraseProblem(newPassphrase) { return problem }
        if !confirmation.isEmpty && confirmation != newPassphrase { return "The new passphrases don\u{2019}t match." }
        return nil
    }

    private var canChange: Bool {
        !isWorking && !oldPassphrase.isEmpty
            && SyncCoordinator.passphraseProblem(newPassphrase) == nil
            && confirmation == newPassphrase
    }

    private func change() {
        guard canChange else { return }
        isWorking = true
        errorMessage = nil
        let old = oldPassphrase
        let new = newPassphrase
        Task {
            do throws(SyncSetupError) {
                try await sync.changePassphrase(old: old, new: new)
                isWorking = false
                onChanged()
                dismiss()
            } catch {
                errorMessage = error.message
                isWorking = false
            }
        }
    }
}

// MARK: - Pieces

/// A Termius card: optional title and subtitle, then the contents.
private struct SyncCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let content: Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(title)
                            .font(.system(size: Theme.cardTitleFontSize, weight: .semibold))
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: Theme.cardSubtitleFontSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .padding(Theme.cardPadding + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A small label over a field.
private struct SyncField<Field: View>: View {
    let title: String
    let field: Field

    init(_ title: String, @ViewBuilder field: () -> Field) {
        self.title = title
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            field
                .frame(maxWidth: 420)
        }
    }
}

/// One radio choice, styled like Settings → Connection's rows (on the card's background).
private struct SyncChoiceRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Theme.cardPadding) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary)
                    Text(detail)
                        .font(.system(size: Theme.cardSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 2, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The server in use and "Disconnect" (to use another server), under the vault setup steps.
private struct SyncServerFooter: View {
    let sync: SyncCoordinator
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(sync.serverURL.map { "Server: \($0.absoluteString)" } ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Use another server") { sync.disconnect() }
                .controlSize(.small)
                .disabled(isDisabled)
                .help("Forget this server and its API key on this Mac")
        }
        .padding(.top, 6)
    }
}

private struct SyncNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SyncErrorText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
