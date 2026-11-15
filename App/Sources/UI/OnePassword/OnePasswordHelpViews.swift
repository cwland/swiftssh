import SwiftUI
import AppCore

/// "Details" under a 1Password error: `op`'s own text (selectable, monospaced), when there is any.
struct OnePasswordErrorDetails: View {
    let error: OnePasswordError
    @State private var isExpanded = false

    /// `op`'s text, unless it is empty or already shown in the message above (notFound / failed).
    private var visibleDetails: String? {
        guard let details = error.details?.trimmingCharacters(in: .whitespacesAndNewlines),
              !details.isEmpty, !error.message.contains(details) else { return nil }
        return error.details
    }

    var body: some View {
        if let details = visibleDetails {
            DisclosureGroup("Details", isExpanded: $isExpanded) {
                Text(details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.system(size: 12))
        }
    }
}

/// A shell command shown monospaced and selectable, with a "Copy" button that says "Copied" briefly.
struct CopyableCommand: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: command)
                .controlSize(.small)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        }
    }
}

/// Copies `text`; its title turns to "Copied" for two seconds.
struct CopyButton: View {
    var title = "Copy"
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : title) {
            OnePasswordSetup.copy(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .help(text)
    }
}

/// Host Details, for a host that logs in with the 1Password agent: copies the command that puts the
/// agent's public keys into `~/.ssh/authorized_keys` on this host, with its port, user and address.
struct KeyInstallCommandButton: View {
    let port: Int
    /// nil or empty: ssh uses the Mac's user name.
    let username: String?
    let address: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CopyButton(title: "Copy key-install command", text: command)
                .controlSize(.small)
            Text("Paste it in Terminal to add your 1Password public keys to this server. It asks for the server\u{2019}s password once.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var command: String {
        let user = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeyInstallCommand.make(port: port,
                                      user: (user?.isEmpty ?? true) ? nil : user,
                                      host: host.isEmpty ? nil : host)
    }
}
