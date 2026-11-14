import SwiftUI
import AppKit
import AppCore

/// The navy tab strip that replaces the window's title bar. The traffic lights sit over its
/// leading inset; empty parts of the bar drag the window.
struct TopBarView: View {
    let navigation: AppNavigation

    var body: some View {
        HStack(spacing: 8) {
            ForEach(navigation.tabs, id: \.self) { tab in
                TopTabPill(tab: tab, isSelected: navigation.selectedTab == tab) {
                    navigation.selectedTab = tab
                }
            }

            Button {
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.topBarForeground)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("SSH sessions arrive in milestone 3")

            Spacer(minLength: 0)

            Image(systemName: "bell")
                .font(.system(size: 15))
                .foregroundStyle(Theme.topBarForeground)
                .frame(width: 32, height: 32)
                .help("Notifications")
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

/// An AppKit view that moves the window when dragged, so the custom top bar behaves like a
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
                window.performDrag(with: event)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
