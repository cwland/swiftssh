import SwiftUI
import AppCore

/// Shown at the top of a terminal whose session ended: why, and a Reconnect button (Cmd+R, from
/// the Session menu). When the failure is fixed in Settings → 1Password, also "Open 1Password Setup";
/// when 1Password's agent doesn't offer the key, "Choose vaults…".
struct DisconnectedBanner: View {
    /// nil for a normal remote close.
    let message: String?
    /// The next step offered next to the message (`TerminalTab.suggestedAction`).
    var suggestedAction: SuggestedAction?
    let reconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message == nil ? "bolt.horizontal.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(message == nil ? Color.secondary : Theme.warningForeground)
            Text(message ?? "Connection closed")
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            switch suggestedAction {
            case .openOnePasswordSetup?:
                OpenOnePasswordSetupButton()
            case .chooseOnePasswordVaults?:
                ChooseVaultsButton()
            case nil:
                EmptyView()
            }
            Button("Reconnect", action: reconnect)
                .help("Reconnect (\u{2318}R)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message == nil ? Color.secondary.opacity(0.12) : Theme.warningBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
