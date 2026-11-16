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

                OnePasswordChecklist(setup: setup)

                PromptFocusToggle(settings: setup.settings)

                AdvancedOverrides(setup: setup)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// What's wrong (with fix buttons), then the five setup steps. Re-checks on appear and whenever the
/// app becomes active. Shown in Settings → 1Password and in the welcome sheet.
struct OnePasswordChecklist: View {
    let setup: OnePasswordSetup
    @State private var choosingVaults = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnePasswordProblemsView(setup: setup)
            VStack(alignment: .leading, spacing: 8) {
                appStep
                agentStep
                cliStep
                integrationStep
                keysStep
            }
        }
        .onAppear { setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.refresh()
        }
        .sheet(isPresented: $choosingVaults) {
            AgentVaultChooserSheet(setup: setup)
        }
    }

    private var checked: Bool { setup.hasChecked }

    /// "Settings → Developer" etc., inside 1Password.
    private var developer: String { OnePasswordLinks.developerSettingsPath }

    // MARK: 1. App

    private var appStep: some View {
        SetupStep(number: 1, title: "1Password app",
                  status: !checked ? .unknown : setup.isAppInstalled ? .done : .missing) {
            if setup.isAppInstalled {
                StepDetail(setup.appURL?.path ?? OnePasswordLinks.appPath, monospaced: true)
            }
            SubStep(1, "Install 1Password 8 for Mac.") {
                if !setup.isAppInstalled {
                    Button("Download 1Password") { setup.openDownloadPage() }
                }
            }
            SubStep(2, "Open 1Password and sign in to your account.") {
                if setup.isAppInstalled {
                    Button("Open 1Password") { setup.openOnePassword() }
                }
            }
            SubStep(3, "Unlock 1Password. Keep it unlocked while you connect.")
            SubStep(4, "In 1Password \u{2192} Settings \u{2192} General, turn on \u{201C}Keep 1Password in the menu bar\u{201D}.")
        }
    }

    // MARK: 2. SSH agent

    private var agentStep: some View {
        SetupStep(number: 2, title: "SSH agent", status: agentStatus) {
            if setup.isAgentBlocked {
                StepNote("macOS is blocking access to 1Password\u{2019}s agent. Do steps 3 to 6. If macOS asks to allow access to data from other apps, click Allow.")
            } else if setup.agentSocketPath != nil, let failure = setup.agentFailure {
                StepNote("The agent isn\u{2019}t answering. Is 1Password open, with \u{201C}Use the SSH agent\u{201D} on? (\(failure))")
            }
            if let path = setup.agentSocketPath {
                StepDetail(path, monospaced: true)
            }
            SubStep(1, "Select your account at the top of 1Password\u{2019}s sidebar, then open \(developer).") {
                Button("Open Developer Settings") { setup.openDeveloperSettings() }
                    .disabled(checked && !setup.isAppInstalled)
                    .accessibilityHint(OnePasswordFix.openDeveloperSettings.accessibilityHint)
            }
            SubStep(2, "Turn on \u{201C}Use the SSH agent\u{201D}.")
            SubStep(3, "macOS 27 or later: open System Settings \u{2192} Privacy & Security \u{2192} Files & Folders.") {
                Button("Open Privacy & Security") { setup.openPrivacySettings() }
                    .accessibilityHint(OnePasswordFix.openPrivacySettings.accessibilityHint)
            }
            SubStep(4, "Under SwiftSSH, turn on \u{201C}Data shared by 1Password\u{201D}.")
            SubStep(5, "Quit SwiftSSH (Cmd+Q) and open it again.")
            SubStep(6, "Click Recheck.") {
                Button("Recheck") { setup.refresh() }
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
                StepNote("Needed only to fill passwords from 1Password.")
            }
            SubStep(1, "Install the CLI with Homebrew, or download the installer.") {
                if !setup.isCLIReady {
                    if setup.homebrewPath != nil {
                        Button("Install with Homebrew") { setup.installWithHomebrew() }
                            .help("Opens Terminal and runs \u{201C}\(OnePasswordLinks.homebrewInstallCommand)\u{201D}")
                    }
                    Button("Download installer") { setup.openCLIDownloadPage() }
                }
            }
            if !setup.isCLIReady {
                CopyableCommand(command: OnePasswordLinks.homebrewInstallCommand)
                    .padding(.leading, SubStepMetrics.indent)
                if let error = setup.installError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, SubStepMetrics.indent)
                }
            }
            SubStep(2, "Come back here. This step turns green by itself.")
            SubStep(3, "For Terminal too (the key-install command), open Files & Folders.") {
                Button("Open Privacy & Security") { setup.openPrivacySettings() }
                    .accessibilityHint(OnePasswordFix.openPrivacySettings.accessibilityHint)
            }
            SubStep(4, "Under Terminal, turn on \u{201C}Data shared by 1Password\u{201D}.")
            SubStep(5, "Quit Terminal (Cmd+Q) and open it again.")
        }
    }

    // MARK: 4. CLI ↔ app

    private var integrationStep: some View {
        SetupStep(number: 4, title: "CLI connected to the app", status: integrationStatus) {
            SubStep(1, "In 1Password, open Settings \u{2192} Security and turn on Touch ID.") {
                Button("Open 1Password") { setup.openOnePassword() }
                    .disabled(checked && !setup.isAppInstalled)
            }
            SubStep(2, "Select your account at the top of 1Password\u{2019}s sidebar (Developer only shows then). Open \(developer) and turn on \u{201C}Integrate with 1Password CLI\u{201D}.") {
                Button("Open Developer Settings") { setup.openDeveloperSettings() }
                    .disabled(checked && !setup.isAppInstalled)
                    .accessibilityHint(OnePasswordFix.openDeveloperSettings.accessibilityHint)
            }
            SubStep(3, "Quit 1Password completely: click its menu bar icon and choose Quit 1Password (Cmd+Q alone may leave it running in the menu bar). Then open it again.")
            SubStep(4, "Quit SwiftSSH (Cmd+Q) and open it again.")
            SubStep(5, "Click Test, then approve 1Password\u{2019}s prompt if one appears.") {
                Button("Test") { setup.testCLI() }
                    .disabled(!setup.isCLIReady || setup.cliTest == .running)
            }
            testResult
                .padding(.leading, SubStepMetrics.indent)
            StepNote("1Password remembers an approval for about 10 minutes, so it won\u{2019}t ask every time.")
        }
    }

    @ViewBuilder
    private var testResult: some View {
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
            // What to do is in the problem card at the top; here only that the test failed, and op's words.
            VStack(alignment: .leading, spacing: 4) {
                Text("The test didn\u{2019}t pass. What to do is shown at the top.")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                OnePasswordErrorDetails(error: error)
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
            agentKeyList
            SubStep(1, "In 1Password, choose New Item \u{2192} SSH Key.") {
                Button("Open 1Password") { setup.openOnePassword() }
                    .disabled(checked && !setup.isAppInstalled)
            }
            SubStep(2, "Generate a key (Ed25519) and save it in the **Private** vault.")
            SubStep(3, "Keys in another vault? Choose the vaults the agent offers keys from.") {
                Button(OnePasswordFix.chooseVaults.title) { choosingVaults = true }
                    .accessibilityHint(OnePasswordFix.chooseVaults.accessibilityHint)
            }
            SubStep(4, "Put the public key on each server: copy this, replace PORT, USER and HOST.")
            CopyableCommand(command: KeyInstallCommand.make(port: nil, user: nil, host: nil))
                .padding(.leading, SubStepMetrics.indent)
            SubStep(5, "Run it in Terminal. It asks for the server\u{2019}s password once.")
            StepNote("Host Details fills in PORT, USER and HOST: \u{201C}Copy key-install command\u{201D} on a host that uses the 1Password SSH agent. Terminal needs \u{201C}Data shared by 1Password\u{201D} too (step 3).")
            StepNote("Synology: turn on Control Panel \u{2192} User & Group \u{2192} Advanced \u{2192} Enable user home service, and run chmod 755 ~ on the NAS.")
            otherVault
        }
    }

    /// Keys in a vault other than Private: 1Password's agent.toml lists the vaults the agent offers.
    private var otherVault: some View {
        DisclosureGroup("Set the vaults by hand instead") {
            VStack(alignment: .leading, spacing: 6) {
                SubStep(1, "Run this in Terminal. It creates the agent\u{2019}s config file and opens it.")
                CopyableCommand(command: OnePasswordLinks.agentConfigCommand)
                    .padding(.leading, SubStepMetrics.indent)
                SubStep(2, "Paste this. Put your vault\u{2019}s name in place of \u{201C}Your vault name\u{201D}.")
                CopyableCommand(command: OnePasswordLinks.agentConfigExample)
                    .padding(.leading, SubStepMetrics.indent)
                SubStep(3, "Save the file, then click Recheck.") {
                    Button("Recheck") { setup.refresh() }
                }
                SubStep(4, "Key still missing? Lock 1Password and unlock it again. Still missing? Quit 1Password completely: click its menu bar icon and choose Quit 1Password (Cmd+Q alone may leave it running in the menu bar). Then open it again.")
                StepNote("Once this file exists, 1Password offers only the vaults listed. Keep \u{201C}Private\u{201D} if you still want it.")
            }
            .padding(.top, 6)
        }
        .font(.system(size: 12, weight: .medium))
    }

    @ViewBuilder
    private var agentKeyList: some View {
        switch setup.agentKeys {
        case .unknown:
            StepDetail("Your keys show here once the SSH agent is found.")
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
            StepDetail("The agent offers no keys yet. Follow the steps below, then Recheck in step 2.")
        case .loaded(let keys):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keys, id: \.publicKeyLine) { key in
                    AgentKeyRow(key: key)
                }
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

private enum SubStepMetrics {
    /// Where a sub-step's text starts: lines that belong to it (commands, results) line up there.
    static let numberWidth: CGFloat = 18
    static let indent: CGFloat = numberWidth + 6
}

/// One checklist row: status symbol, number and title, then its contents (sub-steps, notes).
private struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    let status: SetupStepStatus
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.cardPadding) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityLabel(accessibilityStatus)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(number). \(title)")
                    .font(.system(size: Theme.cardTitleFontSize, weight: .semibold))
                content
            }
            .controlSize(.small)
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

/// "1. One short instruction" with the buttons for that instruction right after it.
/// The text takes **bold** markdown.
private struct SubStep<Actions: View>: View {
    let number: Int
    let text: String
    let actions: Actions

    init(_ number: Int, _ text: String, @ViewBuilder actions: () -> Actions) {
        self.number = number
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: SubStepMetrics.numberWidth, alignment: .trailing)
            Text(LocalizedStringKey(text))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                actions
            }
            .fixedSize()
        }
    }
}

extension SubStep where Actions == EmptyView {
    init(_ number: Int, _ text: String) {
        self.init(number, text) { EmptyView() }
    }
}

/// Secondary 12 pt text that wraps (paths, versions, statuses).
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

/// A short note with an info symbol, indented with the sub-steps.
private struct StepNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: SubStepMetrics.numberWidth, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    /// Why the socket override was not saved; shown under the field.
    @State private var socketError: String?
    @FocusState private var focused: Field?

    private enum Field { case socket, cli }

    var body: some View {
        DisclosureGroup("Advanced", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                overrideField(title: "SSH agent socket", text: $socketText, field: .socket,
                         placeholder: OnePasswordPaths.agentSocketCandidates.first ?? "")
                if let socketError {
                    Text(socketError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            if let value, let message = OnePasswordPaths.validateSocketOverride(value) {
                // Not saved: the previous override (or the standard places) stays in use.
                socketError = message
                return
            }
            socketError = nil
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

/// "Bring 1Password's prompt to the front": `OnePasswordSettings.bringsPromptForward`.
private struct PromptFocusToggle: View {
    @Bindable var settings: OnePasswordSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Bring 1Password\u{2019}s Touch ID prompt to the front", isOn: $settings.bringsPromptForward)
            Text("When 1Password asks you to approve a sign-in, it gets the keyboard focus so the prompt can be answered right away, and this app takes the focus back afterwards. Turn this off if it brings 1Password\u{2019}s main window forward.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
