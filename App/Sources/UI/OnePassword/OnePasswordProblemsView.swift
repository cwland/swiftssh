import SwiftUI
import AppCore
import SwiftSSHUI

/// The top of the 1Password checklist: each problem `OnePasswordDiagnosis` found, in plain words,
/// with the buttons that fix it. "All set" when there are none.
struct OnePasswordProblemsView: View {
    let setup: OnePasswordSetup

    var body: some View {
        let problems = setup.problems
        VStack(alignment: .leading, spacing: 8) {
            if !setup.hasChecked {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking 1Password\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if problems.isEmpty {
                Label(allSetText, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            } else {
                ForEach(problems) { problem in
                    OnePasswordProblemCard(problem: problem, setup: setup)
                }
            }
        }
    }

    /// The CLI test hasn't run: say so, rather than claiming everything works.
    private var allSetText: String {
        setup.cliTest == .passed || !setup.isCLIReady
            ? "1Password is set up."
            : "1Password looks set up. Click Test in step 4 to check the CLI."
    }
}

/// One problem: warning symbol, title, what to do, and its fix buttons.
struct OnePasswordProblemCard: View {
    let problem: OnePasswordProblem
    let setup: OnePasswordSetup

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warningForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(problem.message)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if case .cliFailed(let error) = problem {
                    OnePasswordErrorDetails(error: error)
                }
                if !problem.fixes.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(problem.fixes, id: \.self) { fix in
                            OnePasswordFixButton(fix: fix, setup: setup)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warningBackground))
        .accessibilityElement(children: .contain)
    }
}

/// A fix button. "Copy install command" says (and announces) "Copied" for a moment; "Choose vaults…"
/// opens the vault chooser sheet; "Recheck" checks everything again.
struct OnePasswordFixButton: View {
    let fix: OnePasswordFix
    let setup: OnePasswordSetup
    @State private var copied = false
    @State private var choosingVaults = false

    var body: some View {
        Button(copied ? "Copied" : fix.title) {
            switch fix {
            case .chooseVaults:
                choosingVaults = true
            case .copyCLIInstallCommand:
                setup.perform(fix)
                copied = true
                AccessibilityNotification.Announcement("Copied").post()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            default:
                setup.perform(fix)
            }
        }
        .accessibilityLabel(copied ? "Copied" : fix.title)
        .accessibilityHint(fix.accessibilityHint)
        .help(fix.accessibilityHint)
        .sheet(isPresented: $choosingVaults) {
            AgentVaultChooserSheet(setup: setup)
        }
    }
}
