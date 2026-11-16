import SwiftUI
import AppCore
import SSHCore

/// "Choose vaults…": which 1Password vaults the SSH agent offers keys from. Lists the vaults with
/// check boxes (vaults holding SSH keys chosen already), shows the current agent.toml, and "Use
/// these vaults" writes the new file (the old one is backed up first), then asks the agent again.
/// The logic is `AgentVaultChooser`.
struct AgentVaultChooserSheet: View {
    let setup: OnePasswordSetup

    @Environment(\.dismiss) private var dismiss
    @State private var chooser: AgentVaultChooser?
    @State private var newVault = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose vaults for the SSH agent")
                    .font(.system(size: 17, weight: .semibold))
                Text("1Password\u{2019}s SSH agent offers keys only from the vaults listed in \(OnePasswordAgentConfigFile.displayPath). Without that file it uses Private.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let chooser {
                content(chooser)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 360, alignment: .top)
        .task {
            guard chooser == nil else { return }
            let made = setup.makeVaultChooser()
            chooser = made
            await made.load()
        }
    }

    @ViewBuilder
    private func content(_ chooser: AgentVaultChooser) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                listStatus(chooser)
                vaultList(chooser)
                addVaultField(chooser)
                if let existing = chooser.existingText {
                    CurrentFile(text: existing, hasOtherEntries: chooser.existingHasOtherEntries,
                                backupURL: chooser.backupURL)
                }
                result(chooser)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        HStack(spacing: 8) {
            if case .done = chooser.phase {
                Button("Recheck") {
                    Task {
                        await chooser.recheck()
                        setup.refresh()
                    }
                }
                .accessibilityHint("Asks 1Password\u{2019}s SSH agent again which keys it offers")
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Use these vaults") {
                Task {
                    await chooser.apply()
                    setup.refresh()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!chooser.canApply)
            .accessibilityHint("Saves \(OnePasswordAgentConfigFile.displayPath) with the chosen vaults")
        }
    }

    @ViewBuilder
    private func listStatus(_ chooser: AgentVaultChooser) -> some View {
        switch chooser.phase {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking 1Password for your vaults\u{2026} Approve 1Password\u{2019}s prompt if one appears.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .listFailed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn\u{2019}t list your vaults. Type their names below instead.")
                    .font(.system(size: 12, weight: .medium))
                Text(error.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            EmptyView()
        }
    }

    private func vaultList(_ chooser: AgentVaultChooser) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chooser.rows) { row in
                Toggle(isOn: Binding(get: { row.isSelected }, set: { _ in chooser.toggle(row.id) })) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.system(size: 13))
                        if let count = row.sshKeyCount, count > 0 {
                            Text(count == 1 ? "1 SSH key" : "\(count) SSH keys")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(chooser.isBusy)
                .accessibilityLabel(row.sshKeyCount.map { "\(row.name), \($0) SSH keys" } ?? row.name)
            }
        }
    }

    private func addVaultField(_ chooser: AgentVaultChooser) -> some View {
        HStack(spacing: 6) {
            TextField("Vault name", text: $newVault, prompt: Text("Another vault, by name"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { add(chooser) }
            Button("Add") { add(chooser) }
                .disabled(newVault.trimmingCharacters(in: .whitespaces).isEmpty || chooser.isBusy)
                .accessibilityLabel("Add vault")
        }
        .controlSize(.small)
    }

    private func add(_ chooser: AgentVaultChooser) {
        if chooser.addVault(named: newVault) { newVault = "" }
    }

    @ViewBuilder
    private func result(_ chooser: AgentVaultChooser) -> some View {
        switch chooser.phase {
        case .saving:
            Text("Saving\u{2026}").font(.system(size: 12)).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saved. Asking the agent again in a few seconds\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .done(let recheck):
            VStack(alignment: .leading, spacing: 6) {
                Label(recheck.message, systemImage: recheckSymbol(recheck))
                    .font(.system(size: 12))
                    .foregroundStyle(recheckColor(recheck))
                    .fixedSize(horizontal: false, vertical: true)
                if case .offers(let keys) = recheck {
                    ForEach(keys, id: \.publicKeyLine) { AgentKeyRow(key: $0) }
                }
            }
        case .saveFailed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .loading, .ready, .listFailed:
            EmptyView()
        }
    }

    private func recheckSymbol(_ recheck: AgentVaultChooser.AgentRecheck) -> String {
        if case .offers = recheck { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private func recheckColor(_ recheck: AgentVaultChooser.AgentRecheck) -> Color {
        if case .offers = recheck { return .green }
        return Theme.warningForeground
    }
}

/// The agent.toml there is now, and where the previous one went.
private struct CurrentFile: View {
    let text: String
    let hasOtherEntries: Bool
    let backupURL: URL?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Current \(OnePasswordAgentConfigFile.displayPath)", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardBackground))
                if let backupURL {
                    Text("The previous file was saved as \(backupURL.lastPathComponent).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(hasOtherEntries
                         ? "It names items or accounts too. \u{201C}Use these vaults\u{201D} replaces it with vaults only; the old file is kept as a backup next to it."
                         : "\u{201C}Use these vaults\u{201D} replaces it; the old file is kept as a backup next to it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 12, weight: .medium))
    }
}

/// "Choose vaults…" next to a connection error: opens the vault chooser. Needs `OnePasswordSetup` in
/// the environment; without it (never in the app) the button doesn't show.
struct ChooseVaultsButton: View {
    @Environment(OnePasswordSetup.self) private var setup: OnePasswordSetup?
    @State private var isPresented = false

    var body: some View {
        if let setup {
            Button(OnePasswordFix.chooseVaults.title) { isPresented = true }
                .help(OnePasswordFix.chooseVaults.accessibilityHint)
                .accessibilityHint(OnePasswordFix.chooseVaults.accessibilityHint)
                .sheet(isPresented: $isPresented) {
                    AgentVaultChooserSheet(setup: setup)
                }
        }
    }
}
