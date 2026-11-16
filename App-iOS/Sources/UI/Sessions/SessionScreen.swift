import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// A session, full screen. (The terminal arrives with the sessions work; for now its state.)
struct SessionScreen: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let vault: LocalVault

    var body: some View {
        VStack(spacing: 16) {
            SessionStatusDot(tab: tab)
            Text(tab.displayTitle)
                .font(.title2.weight(.semibold))
            HStack {
                Button("Hosts") { sessions.selectedTabID = nil }
                Button("Close", role: .destructive) { sessions.close(tabID: tab.id) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }
}
