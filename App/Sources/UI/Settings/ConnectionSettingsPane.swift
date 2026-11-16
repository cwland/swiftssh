import SwiftUI
import AppCore

/// Settings → Connection: reconnecting automatically, a note on how drops are noticed (fixed, nothing to
/// tune), and whether closing an unsaved workspace asks to save it. Saved by `ConnectionSettings`, on
/// this Mac only.
struct ConnectionSettingsPane: View {
    let settings: ConnectionSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connection")
                    .font(.system(size: 22, weight: .semibold))

                Toggle(isOn: Binding(get: { settings.autoReconnect },
                                     set: { settings.autoReconnect = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reconnect automatically")
                            .font(.system(size: Theme.cardTitleFontSize))
                        Text("When a connection drops or the server restarts, try again every few seconds for about 3 minutes. You can also reconnect or close the tab from the popup.")
                            .font(.system(size: Theme.cardSubtitleFontSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Text("Dropped connections are noticed within seconds: the app checks the server every 5 seconds, right away when what you type gets no answer, and when the Mac\u{2019}s network changes or it wakes from sleep.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .padding(.vertical, 4)

                Text("Workspaces")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Toggle(isOn: Binding(get: { settings.askToSaveWorkspaces },
                                     set: { settings.askToSaveWorkspaces = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask to save workspaces when closing")
                            .font(.system(size: Theme.cardTitleFontSize))
                        Text("Closing a split view workspace with unsaved changes asks whether to save it first.")
                            .font(.system(size: Theme.cardSubtitleFontSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
