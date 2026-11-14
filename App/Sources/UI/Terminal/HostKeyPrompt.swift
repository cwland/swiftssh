import SwiftUI
import SSHCore

/// Sheet asking whether to trust a server's host key: first contact (`unknown`), a key type not
/// seen before for a known server (`newKeyType`), or a changed key (`changed`, shown as a warning
/// with Cancel as the default).
struct HostKeyPrompt: View {
    let candidate: HostKeyCandidate
    let check: HostKeyCheck
    let answer: (HostKeyDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch check {
            case .changed(let previous):
                changedContent(previousFingerprint: previous)
            case .newKeyType:
                trustContent(
                    title: "New key type for this server",
                    note: "The server presented a key type not seen before."
                )
            case .unknown, .known:
                trustContent(title: "Trust this server?", note: nil)
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
    }

    // MARK: Unknown and new key type

    @ViewBuilder
    private func trustContent(title: String, note: String?) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
        if let note {
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        keyDetails(fingerprintRows: [("Fingerprint", candidate.fingerprint)])
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { answer(.rejected) }
                .keyboardShortcut(.cancelAction)
            Button("Trust and Connect") { answer(.trusted) }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Changed

    @ViewBuilder
    private func changedContent(previousFingerprint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
            Text("The server's identity has changed")
                .font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(Color.red)
        keyDetails(fingerprintRows: [
            ("Previous fingerprint", previousFingerprint),
            ("New fingerprint", candidate.fingerprint),
        ])
        Text("This can mean someone is intercepting the connection to read or change what you send. "
             + "It can also happen when the server was reinstalled or its key was replaced. "
             + "Only trust the new key if you know why it changed.")
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            // Escape cancels too (Return already picks Cancel, the default button).
            Button("Cancel (Escape)") { answer(.rejected) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            Spacer()
            Button("Remove Old Key and Trust New", role: .destructive) { answer(.trusted) }
            Button("Cancel", role: .cancel) { answer(.rejected) }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Details

    private func keyDetails(fingerprintRows: [(String, String)]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            detailRow("Host", candidate.hostPort, monospaced: false)
            detailRow("Key type", candidate.keyType, monospaced: false)
            ForEach(fingerprintRows.indices, id: \.self) { index in
                detailRow(fingerprintRows[index].0, fingerprintRows[index].1, monospaced: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
