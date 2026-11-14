import SwiftUI

/// Shown at the top of a terminal whose session ended: why, and a Reconnect button (Cmd+R, from
/// the Session menu).
struct DisconnectedBanner: View {
    /// nil for a normal remote close.
    let message: String?
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
