import SwiftUI
import AppCore
import CoreModels
import SSHCore
import SwiftSSHUI

/// How a host's direct credentials or an identity log in.
enum LoginMethod: Hashable {
    /// The stored password and/or key (a password may be a 1Password reference).
    case passwordOrKey
    /// The 1Password SSH agent (`agentKey` non-nil).
    case onePasswordAgent

    init(agentKey: AgentKeyChoice?) {
        self = agentKey == nil ? .passwordOrKey : .onePasswordAgent
    }
}

/// "Log in with": Password or key / 1Password SSH agent.
struct LoginMethodPicker: View {
    @Binding var method: LoginMethod

    var body: some View {
        FieldColumn(title: "Log in with") {
            Picker("Log in with", selection: $method) {
                Text("Password or key").tag(LoginMethod.passwordOrKey)
                Text("1Password SSH agent").tag(LoginMethod.onePasswordAgent)
            }
            .labelsHidden()
        }
    }
}

/// A password field that also takes a 1Password secret reference: "Pick from 1Password…" fills
/// `op://…`, which then shows as a chip with a clear button instead of the secure field.
struct OnePasswordPasswordField: View {
    let title: String
    @Binding var text: String
    /// Gets a reference picked from 1Password instead of `text`, so the editor can ask whether to
    /// remove replaced secrets first. nil: the reference goes straight into `text`.
    var pick: ((String) -> Void)? = nil

    @Environment(OnePasswordSetup.self) private var onePassword: OnePasswordSetup?
    @State private var showPicker = false
    /// The reference chosen in the sheet, handed on once the sheet is gone (an alert may follow).
    @State private var pickedReference: String?
    /// Set once "Pick from 1Password…" was tapped; until then (and without an `op://` value) no hint shows.
    @State private var pickerRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if SecretReference.isReference(text) {
                OnePasswordReferenceChip(reference: text, displayName: onePassword?.displayName(for: text)) { text = "" }
            } else {
                RevealableSecureField(title: title, text: $text)
            }
            if onePassword != nil {
                Button("Pick from 1Password\u{2026}") {
                    // Only `op`'s status: listing agent keys here could trigger macOS's
                    // "access data from other apps" prompt.
                    onePassword?.refreshCLIStatus()
                    pickerRequested = true
                    showPicker = true
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .help("Use a password kept in 1Password. It is read from 1Password each time you connect.")
                if let onePassword, pickerRequested || SecretReference.isReference(text),
                   onePassword.hasCheckedCLI, !onePassword.isCLIReady {
                    OnePasswordSetupHint(detail: "Filling passwords needs the 1Password CLI.")
                }
            }
        }
        .onAppear {
            // Opening Host Details checks nothing unless the field already holds a reference.
            if SecretReference.isReference(text) { onePassword?.refreshCLIStatus() }
        }
        .sheet(isPresented: $showPicker, onDismiss: handOnPickedReference) {
            OnePasswordItemPicker(client: onePassword?.makeClient(),
                                  onItemsLoaded: { onePassword?.remember(items: $0) }) { reference in
                pickedReference = reference
                showPicker = false
            } cancel: {
                showPicker = false
            }
        }
    }

    private func handOnPickedReference() {
        guard let reference = pickedReference else { return }
        pickedReference = nil
        if let pick {
            pick(reference)
        } else {
            text = reference
        }
    }
}

/// "1Password: Vault / Item / field" with a clear button. Shows names when `displayName` is known
/// (the reference holds IDs), else the reference text; never a secret.
struct OnePasswordReferenceChip: View {
    let reference: String
    var displayName: String?
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal.fill")
                .foregroundStyle(Theme.accent)
            Text("1Password: \(displayName ?? Self.displayPath(reference))")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(reference)
            Spacer(minLength: 4)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop using 1Password for this password")
            .accessibilityLabel("Clear 1Password reference")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            Capsule(style: .continuous)
                .fill(Theme.accent.opacity(0.12))
        }
        .accessibilityElement(children: .combine)
    }

    /// "op://Private/Server/password" → "Private/Server/password" (query options dropped).
    static func displayPath(_ reference: String) -> String {
        var path = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.lowercased().hasPrefix("op://") { path.removeFirst(5) }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return path.removingPercentEncoding ?? path
    }
}

/// The agent key to log in with: "Any key" (the agent offers its keys in turn) or one pinned key.
/// Bound to a non-nil `AgentKeyChoice`; a pinned key the agent doesn't offer now stays selectable.
struct OnePasswordAgentKeyPicker: View {
    @Binding var choice: AgentKeyChoice?

    @Environment(OnePasswordSetup.self) private var onePassword: OnePasswordSetup?

    var body: some View {
        FieldColumn(title: "1Password key") {
            Picker("1Password key", selection: selection) {
                Text("Any key").tag(String?.none)
                ForEach(keys, id: \.publicKeyLine) { key in
                    Text(Self.label(key)).tag(String?.some(key.publicKeyLine))
                }
                if let pinned = choice?.publicKey, matchingKey(pinned) == nil {
                    Text("Chosen key (not offered by 1Password now)").tag(String?.some(pinned))
                }
            }
            .labelsHidden()
            if let pinned = choice?.publicKey, let key = matchingKey(pinned) {
                Text("\(key.type)  \(key.fingerprint)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else if choice?.publicKey == nil {
                Text("1Password offers its keys one after another. With many keys, pick one to avoid \u{201C}Too many authentication failures\u{201D}.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onePassword, onePassword.hasChecked, !onePassword.isAgentReady {
                OnePasswordSetupHint(detail: onePassword.isAgentBlocked
                                     ? "macOS is blocking access to 1Password\u{2019}s agent."
                                     : onePassword.agentFailure
                                         ?? "1Password\u{2019}s SSH agent wasn\u{2019}t found.")
            }
        }
        .onAppear { onePassword?.refresh() }
    }

    private var keys: [AgentKey] {
        if case .loaded(let keys) = onePassword?.agentKeys { return keys }
        return []
    }

    /// The agent key with the same type and key data (comments may differ).
    private func matchingKey(_ line: String) -> AgentKey? {
        let body = Self.keyBody(line)
        return keys.first { Self.keyBody($0.publicKeyLine) == body }
    }

    /// The picker's tag: a pinned key shows as the agent's matching entry when there is one.
    private var selection: Binding<String?> {
        Binding(
            get: {
                guard let pinned = choice?.publicKey else { return nil }
                return matchingKey(pinned)?.publicKeyLine ?? pinned
            },
            set: { choice = AgentKeyChoice(publicKey: $0) }
        )
    }

    /// "type base64" of a public key line.
    static func keyBody(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
    }

    static func label(_ key: AgentKey) -> String {
        key.comment.isEmpty ? "\(key.type) \u{2014} \(key.fingerprint)" : "\(key.comment) (\(key.type))"
    }
}

/// "1Password isn't set up yet — Open setup", inline in an editor.
struct OnePasswordSetupHint: View {
    var detail: String?
    /// Runs before Settings opens (e.g. to close a sheet).
    var before: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warningForeground)
            VStack(alignment: .leading, spacing: 2) {
                Text("1Password isn\u{2019}t set up yet")
                    .font(.system(size: 12, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                OpenOnePasswordSetupButton(title: "Open setup", before: before)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
    }
}
