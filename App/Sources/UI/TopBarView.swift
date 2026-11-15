import SwiftUI
import AppKit
import AppCore

/// The navy tab strip that replaces the window's title bar: Vaults, then one tab per terminal
/// session. The traffic lights sit over its leading inset; empty parts of the bar drag the window.
struct TopBarView: View {
    let navigation: AppNavigation
    /// nil until the vault is open.
    let sessions: SessionManager?
    /// nil until the vault is open; drives the Vaults tab's cloud icon.
    let sync: SyncCoordinator?
    let selectVaults: () -> Void
    let closeTab: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(navigation.tabs, id: \.self) { tab in
                TopTabPill(tab: tab, isSelected: sessions?.selectedTabID == nil, sync: sync) {
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

/// A top tab (Vaults). The Vaults tab also holds the sync cloud icon, a button of its own beside
/// the tab's button (so a click on the icon opens the sync popover rather than selecting the tab).
private struct TopTabPill: View {
    let tab: TopTab
    let isSelected: Bool
    let sync: SyncCoordinator?
    let action: () -> Void

    private var showsSyncIcon: Bool {
        guard tab == .vaults, let sync else { return false }
        return sync.phase.cloudSymbol != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: tab.systemImage)
                    Text(tab.title)
                        .font(.system(size: Theme.tabFontSize))
                }
                .padding(.leading, 12)
                .padding(.trailing, showsSyncIcon ? 6 : 12)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Vaults (\u{2318}1)")

            if showsSyncIcon, let sync {
                SyncCloudButton(sync: sync)
                    .padding(.trailing, 8)
            }
        }
        .foregroundStyle(Theme.topBarForeground)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous)
                .fill(isSelected ? Theme.tabBackground : Color.clear)
        )
    }
}

/// A terminal session tab, Termius layout: a leading slot, then the host label. The slot shows the
/// OS badge; on the selected tab and while the pointer is over the tab it shows the close button
/// instead (closing never asks). Titles shrink (truncating) when many tabs are open.
private struct SessionTabPill: View {
    let tab: TerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    private static let slotSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            leadingSlot
                .frame(width: Self.slotSize, height: Self.slotSize)

            Text(tab.title.isEmpty ? "Untitled host" : tab.title)
                .font(.system(size: Theme.tabFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, select)
        }
        .foregroundStyle(Theme.topBarForeground)
        .padding(.leading, 7)
        .padding(.trailing, 12)
        // Only a maximum: the pill hugs its content up to 220 pt (the title truncates beyond that)
        // and shrinks when the bar is crowded.
        .frame(maxWidth: 220, alignment: .leading)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous)
                .fill(isSelected ? Theme.tabBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous))
        // A click anywhere on the pill selects the tab; the close button in the leading slot
        // handles its own clicks first.
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Close tab", close)
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if isSelected || isHovering {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: Self.slotSize, height: Self.slotSize)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (\u{2318}W)")
            .accessibilityLabel("Close tab")
        } else {
            BadgeView(badge: tab.badge, size: Self.slotSize)
                .opacity(isLive ? 1 : 0.5)
        }
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
