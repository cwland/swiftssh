import SwiftUI
import AppCore
import SSHCore
import SwiftSSHUI

/// What a session is asking, derived from its state.
enum SessionPrompt: Identifiable {
    case hostKey(HostKeyCandidate, HostKeyCheck)
    case password(String)

    init?(state: TerminalTab.State) {
        switch state {
        case .awaitingHostKey(let candidate, let check):
            self = .hostKey(candidate, check)
        case .awaitingPassword(let prompt):
            self = .password(prompt)
        case .connecting, .connected, .disconnected:
            return nil
        }
    }

    /// A new prompt (another key, another password question) gets a new sheet.
    var id: String {
        switch self {
        case .hostKey(let candidate, let check):
            "hostKey|\(candidate.hostPort)|\(candidate.keyType)|\(candidate.fingerprint)|\(check)"
        case .password(let prompt):
            "password|\(prompt)"
        }
    }
}

/// Whether to trust a server's key: first contact, a key type not seen before (Cancel first), or a
/// changed key (a warning, Cancel first).
struct HostKeyPromptSheet: View {
    let candidate: HostKeyCandidate
    let check: HostKeyCheck
    let answer: (HostKeyDecision) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch check {
                    case .changed:
                        Label("The server\u{2019}s identity has changed", systemImage: "exclamationmark.octagon.fill")
                            .font(.headline)
                            .foregroundStyle(Color.red)
                        Text("This can mean someone is intercepting the connection to read or change what you send. "
                             + "It can also happen when the server was reinstalled or its key was replaced. "
                             + "Only trust the new key if you know why it changed.")
                    case .newKeyType(let known):
                        Text(Self.newKeyTypeNote(known: known, new: candidate.keyType))
                    case .unknown, .known:
                        Text("SwiftSSH hasn\u{2019}t seen this server before. Check that the fingerprint is the one you expect.")
                    }
                }
                Section("Key") {
                    LabeledContent("Host", value: candidate.hostPort)
                    LabeledContent("Key type", value: candidate.keyType)
                    if case .changed(let previous) = check {
                        fingerprint("Previous fingerprint", previous)
                        fingerprint("New fingerprint", candidate.fingerprint)
                    } else {
                        fingerprint("Fingerprint", candidate.fingerprint)
                    }
                }
                Section {
                    if case .changed = check {
                        Button("Remove Old Key and Trust New", role: .destructive) { answer(.trusted) }
                    } else {
                        Button("Trust and Connect") { answer(.trusted) }
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { answer(.rejected) }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private var title: String {
        switch check {
        case .changed: "Identity Changed"
        case .newKeyType: "New Key Type"
        case .unknown, .known: "Trust This Server?"
        }
    }

    private func fingerprint(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    /// Names the key types already trusted for this host and the new one, and warns what an
    /// unexpected change can mean.
    static func newKeyTypeNote(known: [String], new: String) -> String {
        let trusted = known.isEmpty ? "other key types" : known.joined(separator: ", ")
        return "You already trust this server\u{2019}s \(trusted) key\(known.count == 1 ? "" : "s"), but it now "
            + "presented a new \(new) key. If you didn\u{2019}t expect this change, someone may be intercepting "
            + "the connection. Only trust the new key if you know why it appeared."
    }
}

/// Asks for a password. The username and password fields are marked for AutoFill, so iOS offers the
/// logins saved in 1Password (or Passwords) above the keyboard. Nothing typed is saved.
struct PasswordPromptSheet: View {
    /// e.g. "Password for root@example.com".
    let prompt: String
    let info: CompanionConnect.PasswordPrompt
    let connect: (String) -> Void
    let cancel: () -> Void

    @State private var password = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let username = info.username {
                        TextField("Username", text: .constant(username))
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(true)
                    }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($fieldFocused)
                        .submitLabel(.go)
                        .onSubmit(submit)
                } header: {
                    Text(prompt)
                        .textCase(nil)
                } footer: {
                    Text(info.onePasswordHint ?? "SwiftSSH doesn\u{2019}t save it on this device.")
                }
            }
            .navigationTitle("Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: submit)
                        .disabled(password.isEmpty)
                }
            }
            .onAppear { fieldFocused = true }
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        connect(password)
    }
}

/// Over a terminal whose live session ended: why, Reconnect, and Import Key when no imported key
/// worked.
struct DisconnectedBanner: View {
    let message: String
    var suggestedAction: SuggestedAction?
    let reconnect: () -> Void
    let importKey: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warningForeground)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer(minLength: 8)
            if suggestedAction == .importKey {
                Button("Import Key", action: importKey)
                    .buttonStyle(.bordered)
            }
            Button("Reconnect", action: reconnect)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningBackground)
    }
}

/// The countdown to the next automatic try, with Reconnect Now and Stop.
struct ReconnectCountdown: View {
    let deadline: Date
    let reconnectNow: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("Reconnecting in \(seconds) s")
                    .font(.footnote.monospacedDigit())
            }
            Button("Now", action: reconnectNow)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Stop", action: stop)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}
