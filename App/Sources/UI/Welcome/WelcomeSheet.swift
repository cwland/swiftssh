import SwiftUI
import AppCore

/// The welcome sheet on a new Mac (and from Help → Set Up SwiftSSH…): 1. join the sync server,
/// 2. set up 1Password, 3. done. Steps 1 and 2 reuse Settings → Sync's flow and Settings →
/// 1Password's checklist, and both can be skipped. When it opens by itself is `WelcomeSetup`.
struct WelcomeSheet: View {
    let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var step: WelcomeSetup.Step = .sync

    private var onePassword: OnePasswordSetup { environment.onePassword }

    var body: some View {
        @Bindable var settings = environment.welcomeSettings
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                stepContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack(spacing: 8) {
                Toggle("Don\u{2019}t show again", isOn: $settings.dontShowAgain)
                    .toggleStyle(.checkbox)
                    .help("Don\u{2019}t open this at launch. Help \u{2192} Set Up SwiftSSH\u{2026} still opens it.")
                Spacer()
                if step != .done {
                    Button("Not Now") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("Closes the welcome. Help \u{2192} Set Up SwiftSSH\u{2026} opens it again.")
                }
                if let previous = step.previous {
                    Button("Back") { step = previous }
                        .accessibilityHint("Goes back to \(previous.title)")
                }
                footerButtons
            }
            .padding(16)
        }
        .frame(width: 640, height: 620)
        .onChange(of: step) { _, _ in
            // VoiceOver: say which step is showing now.
            AccessibilityNotification.Announcement("\(step.progress): \(heading)").post()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.progress)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(heading)
                .font(.system(size: 22, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var heading: String { step == .sync ? "Welcome to SwiftSSH" : step.title }

    private var subtitle: String {
        switch step {
        case .sync:
            "Join your sync server to get your hosts, keys and snippets from your other Macs. You can skip this and do it later in Settings \u{2192} Sync."
        case .onePassword:
            "Log in with SSH keys kept in 1Password, and fill passwords from it. You can skip this and do it later in Settings \u{2192} 1Password."
        case .done:
            "Open this again any time from Help \u{2192} Set Up SwiftSSH\u{2026}"
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .sync:
            SyncSetupFlow(sync: environment.sync, vault: environment.vault)
        case .onePassword:
            VStack(alignment: .leading, spacing: 12) {
                if onePassword.hasChecked && !onePassword.isAppInstalled {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1Password isn\u{2019}t installed on this Mac. Skip this step if you don\u{2019}t use it.")
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                            Button(OnePasswordFix.downloadApp.title) { onePassword.openDownloadPage() }
                                .controlSize(.small)
                                .accessibilityHint(OnePasswordFix.downloadApp.accessibilityHint)
                        }
                    }
                }
                OnePasswordChecklist(setup: onePassword)
            }
        case .done:
            VStack(alignment: .leading, spacing: 10) {
                summaryRow("Sync", done: syncIsSetUp,
                           detail: syncIsSetUp ? "Joined your sync server." : "Not set up. Settings \u{2192} Sync.")
                summaryRow("1Password", done: onePasswordIsSetUp,
                           detail: onePasswordIsSetUp ? "Set up." : onePasswordDetail)
            }
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch step {
        case .sync:
            Button(syncIsSetUp ? "Next" : "Skip") { step = .onePassword }
                .accessibilityHint(syncIsSetUp ? "Goes to Set up 1Password" : "Skips sync and goes to Set up 1Password")
        case .onePassword:
            Button(onePasswordIsSetUp ? "Next" : "Skip") { step = .done }
                .accessibilityHint(onePasswordIsSetUp ? "Goes to the last step" : "Skips 1Password and goes to the last step")
        case .done:
            Button("Done") {
                environment.welcomeSettings.dontShowAgain = true
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Closes the welcome. It won\u{2019}t open by itself again.")
        }
    }

    private func summaryRow(_ title: String, done: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(done ? "set up" : "not set up"). \(detail)")
    }

    /// Joined and syncing (or waiting for the next sync).
    private var syncIsSetUp: Bool {
        guard let phase = environment.sync?.phase else { return false }
        switch phase {
        case .idle, .syncing, .offline: return true
        case .notConfigured, .needsVault, .locked, .failed: return false
        }
    }

    private var onePasswordIsSetUp: Bool {
        onePassword.hasChecked && onePassword.isAppInstalled && onePassword.problems.isEmpty
    }

    private var onePasswordDetail: String {
        if onePassword.hasChecked && !onePassword.isAppInstalled { return "Not installed. Settings \u{2192} 1Password when you want it." }
        return "Not finished. Settings \u{2192} 1Password shows what\u{2019}s left."
    }
}
