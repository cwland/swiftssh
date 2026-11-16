import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// iPad: the open sessions as tabs across the top, in the Mac's navy bar. "Hosts" goes back to the
/// sections; tap a tab to switch, × to close it.
struct SessionTabBar: View {
    let sessions: SessionManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabButton(title: "Hosts", symbol: "square.grid.2x2", isSelected: sessions.selectedTabID == nil) {
                    sessions.selectedTabID = nil
                }
                ForEach(sessions.tabs) { tab in
                    SessionTabItem(tab: tab, isSelected: sessions.selectedTabID == tab.id,
                                   select: { sessions.selectedTabID = tab.id },
                                   close: { sessions.close(tabID: tab.id) })
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Theme.topBarBackground)
    }

    private func tabButton(title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.topBarForeground)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.tabBackground : Theme.tabInactiveBackground))
        }
        .buttonStyle(.plain)
    }
}

/// One session tab: status dot, OS badge, name, close button.
private struct SessionTabItem: View {
    let tab: TerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    SessionStatusDot(tab: tab)
                    OSBadgeTile(badge: tab.badge, size: 18, cornerRadius: 4)
                    Text(tab.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Session \(tab.displayTitle)")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.displayTitle)")
        }
        .foregroundStyle(Theme.topBarForeground)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Theme.tabBackground : Theme.tabInactiveBackground))
    }
}

/// Green when connected, amber while connecting or asking, red when disconnected.
struct SessionStatusDot: View {
    let tab: TerminalTab

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tab.state {
        case .connected: .green
        case .connecting, .awaitingHostKey, .awaitingPassword: .orange
        case .disconnected: .red
        }
    }
}

/// The menu of open sessions (and "Hosts"), shared by the iPhone pill and session screen.
struct SessionMenuItems: View {
    let sessions: SessionManager

    var body: some View {
        Button {
            sessions.selectedTabID = nil
        } label: {
            Label("Hosts", systemImage: "square.grid.2x2")
        }
        Section("Sessions") {
            ForEach(sessions.tabs) { tab in
                Button {
                    sessions.selectedTabID = tab.id
                } label: {
                    if sessions.selectedTabID == tab.id {
                        Label(tab.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(tab.displayTitle)
                    }
                }
            }
        }
    }
}

/// iPhone: a floating pill over Hosts naming the open sessions; tap to go back to one.
struct SessionPill: View {
    let sessions: SessionManager

    var body: some View {
        Menu {
            SessionMenuItems(sessions: sessions)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                Text(sessions.tabs.count == 1 ? sessions.tabs[0].displayTitle : "\(sessions.tabs.count) sessions")
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.topBarForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.topBarBackground))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
        .accessibilityLabel("Open sessions")
    }
}
