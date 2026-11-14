import SwiftUI
import AppKit
import AppCore

/// The navy tab strip that replaces the window's title bar: Vaults, then one tab per terminal
/// session. The traffic lights sit over its leading inset; empty parts of the bar drag the window.
struct TopBarView: View {
    let navigation: AppNavigation
    /// nil until the vault is open.
    let sessions: SessionManager?
    let selectVaults: () -> Void
    let closeTab: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(navigation.tabs, id: \.self) { tab in
                TopTabPill(tab: tab, isSelected: sessions?.selectedTabID == nil) {
                    selectVaults()
                }
                .layoutPriority(1)
            }

            if let sessions {
                ForEach(sessions.tabs) { tab in
                    SessionTabPill(
                        tab: tab,
                        isSelected: sessions.selectedTabID == tab.id,
                        select: { sessions.selectedTabID = tab.id },
                        close: { closeTab(tab.id) }
                    )
                }
            }

            Button {
                selectVaults()
                navigation.sidebar = .hosts
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.topBarForeground)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .help("New connection: pick a host or type user@host")

            Spacer(minLength: 0)

            Image(systemName: "bell")
                .font(.system(size: 15))
                .foregroundStyle(Theme.topBarForeground)
                .frame(width: 32, height: 32)
                .help("Notifications")
                .layoutPriority(1)
        }
        .padding(.leading, Theme.trafficLightInset)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.topBarHeight)
        .background {
            ZStack {
                Theme.topBarBackground
                WindowDragArea()
            }
        }
    }
}

private struct TopTabPill: View {
    let tab: TopTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                Text(tab.title)
                    .font(.system(size: Theme.tabFontSize))
                if tab == .vaults {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 12))
                        .opacity(0.7)
                        .help("Sync is not set up")
                }
            }
            .foregroundStyle(Theme.topBarForeground)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous)
                    .fill(isSelected ? Theme.tabBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Vaults (\u{2318}1)")
    }
}

/// A terminal session tab: OS badge, host label and a close button. Titles shrink (truncating)
/// when many tabs are open.
private struct SessionTabPill: View {
    let tab: TerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 8) {
                    BadgeView(badge: tab.badge, size: 20)
                        .opacity(isLive ? 1 : 0.5)
                    Text(tab.title.isEmpty ? "Untitled host" : tab.title)
                        .font(.system(size: Theme.tabFontSize))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.8)
            .help("Close (\u{2318}W)")
        }
        .foregroundStyle(Theme.topBarForeground)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 70, maxWidth: 220, alignment: .leading)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous)
                .fill(isSelected ? Theme.tabBackground : Color.clear)
        )
    }

    /// Dims the badge while the tab has no live session.
    private var isLive: Bool {
        switch tab.state {
        case .connected: true
        case .connecting, .awaitingHostKey, .awaitingPassword, .disconnected: false
        }
    }
}

extension TopTab {
    var title: String {
        switch self {
        case .vaults: "Vaults"
        }
    }

    var systemImage: String {
        switch self {
        case .vaults: "square.stack.3d.up.fill"
        }
    }
}

/// An AppKit view that moves the window when dragged and zooms it on double-click, so the custom top bar behaves like a
/// title bar.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if let window {
                if event.clickCount == 2 {
                    window.performZoom(nil)
                } else {
                    window.performDrag(with: event)
                }
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
