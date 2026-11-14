import SwiftUI
import AppKit
import Combine
import AppCore
import SSHCore

/// Settings → 1Password: a setup checklist with live status (re-checked on appear and whenever the
/// app becomes active), then Advanced path overrides saved by `OnePasswordSettings`.
struct OnePasswordSettingsPane: View {
    let setup: OnePasswordSetup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1Password")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Log in with SSH keys kept in 1Password, and fill passwords from 1Password when you connect. Nothing from 1Password is stored in the vault \u{2014} only which key or item to use.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    appStep
                    agentStep
                    cliStep
                    integrationStep
                    keysStep
                }

                AdvancedOverrides(setup: setup)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.refresh()
        }
    }

    private var checked: Bool { setup.hasChecked }

    // MARK: 1. App

    private var appStep: some View {
        SetupStep(number: 1, title: "1Password app",
                  status: !checked ? .unknown : setup.isAppInstalled ? .done : .missing) {
            if setup.isAppInstalled {
                StepDetail(setup.appURL?.path ?? OnePasswordLinks.appPath, monospaced: true)
            } else {
                StepDetail("1Password 8 for Mac is needed for the SSH agent and the CLI.")
            }
        } actions: {
            if !setup.isAppInstalled {
                Button("Download 1Password") { setup.openDownloadPage() }
            }
        }
    }

    // MARK: 2. SSH agent

    private var agentStep: some View {
        SetupStep(number: 2, title: "SSH agent", status: agentStatus) {
            if setup.isAgentBlocked {
                StepDetail("macOS is blocking access to 1Password\u{2019}s agent. If macOS asks whether Termius Reimagined may access data from other apps, click Allow \u{2014} or turn it on in System Settings \u{2192} Privacy & Security \u{2192} App Management.")
                if let path = setup.agentSocketPath {
                    StepDetail(path, monospaced: true)
                }
            } else if let path = setup.agentSocketPath {
                StepDetail(path, monospaced: true)
            } else {
                StepDetail("In 1Password, open \(OnePasswordLinks.developerSettingsPath) and turn on \u{201C}Use the SSH agent\u{201D}.")
            }
        } actions: {
            if setup.isAgentBlocked {
                Button("Open Privacy Settings") { setup.openPrivacySettings() }
                Button("Recheck") { setup.refresh() }
            } else if setup.agentSocketPath == nil {
                Button("Open 1Password") { setup.openOnePassword() }
                    .disabled(checked && !setup.isAppInstalled)
                    .help("Opens 1Password; then go to \(OnePasswordLinks.developerSettingsPath)")
            }
        }
    }

    private var agentStatus: SetupStepStatus {
        guard checked else { return .unknown }
        if setup.isAgentBlocked { return .blocked }
        return setup.isAgentReady ? .done : .missing
    }

    // MARK: 3. CLI

    private var cliStep: some View {
        SetupStep(number: 3, title: "1Password CLI",
                  status: !checked ? .unknown : setup.isCLIReady ? .done : .missing) {
            if let path = setup.cliPath {
                StepDetail(setup.cliVersion.map { "\(path) \u{2014} version \($0)" } ?? path, monospaced: true)
            } else {
                StepDetail("Needed only to fill passwords from 1Password. Install it, then come back \u{2014} this list updates by itself.")
                Text(OnePasswordLinks.homebrewInstallCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                if let error = setup.installError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            if !setup.isCLIReady {
                if setup.homebrewPath != nil {
                    Button("Install with Homebrew") { setup.installWithHomebrew() }
                        .help("Opens Terminal and runs \u{201C}\(OnePasswordLinks.homebrewInstallCommand)\u{201D}")
                }
                Button("Download installer") { setup.openCLIDownloadPage() }
                Button("Copy command") { setup.copyInstallCommand() }
                    .help(OnePasswordLinks.homebrewInstallCommand)
            }
        }
    }

    // MARK: 4. CLI ↔ app

    private var integrationStep: some View {
        SetupStep(number: 4, title: "CLI connected to the app", status: integrationStatus) {
            StepDetail("In 1Password \u{2192} \(OnePasswordLinks.developerSettingsPath), turn on \u{201C}Integrate with 1Password CLI\u{201D}. Test may show a 1Password or Touch ID prompt.")
            switch setup.cliTest {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for 1Password\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            case .passed:
                Text("Connected.")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            case .failed(let error):
                Text(error.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Test") { setup.testCLI() }
                .disabled(!setup.isCLIReady || setup.cliTest == .running)
            if case .failed = setup.cliTest, setup.isAppInstalled {
                Button("Open 1Password") { setup.openOnePassword() }
            }
        }
    }

    private var integrationStatus: SetupStepStatus {
        switch setup.cliTest {
        case .passed: .done
        case .failed: .missing
        case .idle, .running: .unknown
        }
    }

    // MARK: 5. Keys

    private var keysStep: some View {
        SetupStep(number: 5, title: "Keys in 1Password", status: keysStatus) {
            switch setup.agentKeys {
            case .unknown:
                StepDetail("Shown once the SSH agent is found.")
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking the agent\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            case .blocked:
                StepDetail("macOS is blocking access to the agent (see step 2).")
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let keys) where keys.isEmpty:
                StepDetail("Add or import an SSH key in 1Password (New Item \u{2192} SSH Key).")
            case .loaded(let keys):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(keys, id: \.publicKeyLine) { key in
                        AgentKeyRow(key: key)
                    }
                }
            }
        } actions: {
            if setup.agentSocketPath != nil {
                Button("Recheck") { setup.refresh() }
            }
        }
    }

    private var keysStatus: SetupStepStatus {
        switch setup.agentKeys {
        case .loaded(let keys): keys.isEmpty ? .missing : .done
        case .blocked: .blocked
        case .failed: .missing
        case .unknown, .loading: .unknown
        }
    }
}

// MARK: - Pieces

private enum SetupStepStatus { case done, missing, blocked, unknown }

/// One checklist row: status symbol, number and title, details, then its buttons.
private struct SetupStep<Detail: View, Actions: View>: View {
    let number: Int
    let title: String
    let status: SetupStepStatus
    @ViewBuilder let detail: Detail
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: Theme.cardPadding) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityLabel(accessibilityStatus)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(number). \(title)")
                    .font(.system(size: Theme.cardTitleFontSize))
                detail
                HStack(spacing: 8) {
                    actions
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .blocked: "lock.circle.fill"
        case .unknown: "circle.dashed"
        }
    }

    private var color: Color {
        switch status {
        case .done: .green
        case .missing, .blocked: Theme.warningForeground
        case .unknown: .secondary
        }
    }

    private var accessibilityStatus: String {
        switch status {
        case .done: "Done"
        case .missing: "Not set up"
        case .blocked: "Blocked by macOS"
        case .unknown: "Not checked"
        }
    }
}

/// Secondary 12 pt text that wraps.
private struct StepDetail: View {
    let text: String
    var monospaced = false

    init(_ text: String, monospaced: Bool = false) {
        self.text = text
        self.monospaced = monospaced
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A key the agent offers: comment (or type), type and fingerprint.
struct AgentKeyRow: View {
    let key: AgentKey

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(key.comment.isEmpty ? key.type : key.comment)
                    .font(.system(size: 13))
                Text("\(key.type)  \(key.fingerprint)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Advanced: the socket and `op` path overrides. Saved on Return or when the field loses focus;
/// empty means use the standard places.
private struct AdvancedOverrides: View {
    let setup: OnePasswordSetup
    @State private var isExpanded = false
    @State private var socketText = ""
    @State private var cliText = ""
    @FocusState private var focused: Field?

    private enum Field { case socket, cli }

    var body: some View {
        DisclosureGroup("Advanced", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                overrideField(title: "SSH agent socket", text: $socketText, field: .socket,
                         placeholder: OnePasswordPaths.agentSocketCandidates.first ?? "")
                overrideField(title: "op path", text: $cliText, field: .cli,
                         placeholder: OnePasswordPaths.cliCandidates.first ?? "")
                Text("Leave empty to look in the standard places. Saved on this Mac only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.system(size: 13, weight: .semibold))
        .onAppear {
            socketText = setup.settings.agentSocketOverride ?? ""
            cliText = setup.settings.cliPathOverride ?? ""
        }
        .onChange(of: focused) { old, _ in
            if let old { commit(old) }
        }
    }

    private func overrideField(title: String, text: Binding<String>, field: Field, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused, equals: field)
                .onSubmit { commit(field) }
        }
    }

    private func commit(_ field: Field) {
        switch field {
        case .socket:
            let value = Self.nonEmpty(socketText)
            guard value != setup.settings.agentSocketOverride else { return }
            setup.settings.agentSocketOverride = value
        case .cli:
            let value = Self.nonEmpty(cliText)
            guard value != setup.settings.cliPathOverride else { return }
            setup.settings.cliPathOverride = value
        }
        setup.refresh()
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
