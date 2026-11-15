import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore

/// The navy tab strip that replaces the window's title bar: Vaults, then one tab per terminal
/// session of this window. The traffic lights sit over its leading inset; empty parts of the bar drag
/// the window. Terminal tabs can be dragged to reorder them (Vaults stays first) and have a right-click
/// menu; Cmd+Shift+[ and Cmd+Shift+] select the previous and next tab in bar order.
struct TopBarView: View {
    let navigation: AppNavigation
    /// nil until the vault is open.
    let sessions: SessionManager?
    /// nil until the vault is open; drives the Vaults tab's cloud icon.
    let sync: SyncCoordinator?
    /// The window this bar belongs to; nil = the main window.
    var windowID: UUID? = nil
    let selectVaults: () -> Void
    let closeTab: (UUID) -> Void
    /// Change Theme…: opens the theme panel over the tab (after selecting it).
    var changeTheme: (UUID) -> Void = { _ in }
    /// Duplicate in New Window.
    var duplicateInNewWindow: (UUID) -> Void = { _ in }

    /// The tab being dragged, for the drop indicator; the drop itself trusts only the dragged payload.
    @State private var draggingTabID: UUID?
    @State private var dropTargetID: UUID?
    @State private var renamingTabID: UUID?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            ForEach(navigation.tabs, id: \.self) { tab in
                TopTabPill(tab: tab, isSelected: sessions?.selectedTabID(inWindow: windowID) == nil, sync: sync) {
                    selectVaults()
                }
                .layoutPriority(1)
            }

            if let sessions {
                let windowTabs = sessions.tabs(inWindow: windowID)
                ForEach(Array(windowTabs.enumerated()), id: \.element.id) { index, tab in
                    SessionTabPill(
                        tab: tab,
                        isSelected: sessions.selectedTabID(inWindow: windowID) == tab.id,
                        select: { sessions.select(tabID: tab.id, inWindow: windowID) },
                        close: { closeTab(tab.id) }
                    )
                    .overlay(alignment: dropIndicatorEdge(for: index, in: windowTabs)) {
                        if dropTargetID == tab.id, draggingTabID != tab.id {
                            DropIndicator()
                        }
                    }
                    .onDrag {
                        draggingTabID = tab.id
                        return NSItemProvider(object: TabDragPayload.string(for: tab.id) as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(
                        targetID: tab.id,
                        targetIndex: index,
                        dropTargetID: $dropTargetID,
                        draggingTabID: $draggingTabID,
                        move: { id, index in
                            // Only tabs of this window reorder here.
                            guard sessions.tabs(inWindow: windowID).contains(where: { $0.id == id }) else { return }
                            withAnimation(.easeOut(duration: 0.15)) {
                                sessions.moveTab(id: id, toIndex: index)
                            }
                        }
                    ))
                    .contextMenu {
                        tabMenu(for: tab, sessions: sessions)
                    }
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
                tabCycleShortcuts
            }
        }
        .alert("Rename Tab", isPresented: renameBinding) {
            TextField("Tab name", text: $renameText)
            Button("Rename") {
                if let id = renamingTabID { sessions?.rename(tabID: id, to: renameText) }
                renamingTabID = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                renamingTabID = nil
            }
        } message: {
            Text("Only this tab is renamed; the host keeps its name. Leave empty to use the host\u{2019}s name.")
        }
    }

    // MARK: Tab menu

    @ViewBuilder
    private func tabMenu(for tab: TerminalTab, sessions: SessionManager) -> some View {
        Button("Change Theme\u{2026}") {
            changeTheme(tab.id)
        }
        Button("Rename\u{2026}") {
            renameText = tab.customTitle ?? tab.title
            renamingTabID = tab.id
        }
        Divider()
        Button("Duplicate") {
            sessions.duplicate(tabID: tab.id)
        }
        Button("Duplicate in New Window") {
            duplicateInNewWindow(tab.id)
        }
        Divider()
        Button("Close") {
            closeTab(tab.id)
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingTabID != nil }, set: { if !$0 { renamingTabID = nil } })
    }

    // MARK: Reordering

    /// The indicator sits where the dragged tab will land: after the target when it comes from the
    /// left, before it otherwise (dropping on a tab takes its place).
    private func dropIndicatorEdge(for index: Int, in windowTabs: [TerminalTab]) -> Alignment {
        guard let draggingTabID, let from = windowTabs.firstIndex(where: { $0.id == draggingTabID }) else {
            return .leading
        }
        return from < index ? .trailing : .leading
    }

    /// Cmd+Shift+[ / Cmd+Shift+]: previous and next tab of this window, in bar order. Invisible buttons,
    /// so the shortcuts work while the terminal has focus.
    private var tabCycleShortcuts: some View {
        ZStack {
            Button("Previous Tab") { sessions?.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { sessions?.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a dragged tab carries: its id, prefixed so text dragged from elsewhere is not taken for a tab.
private enum TabDragPayload {
    static let prefix = "termius-reimagined-tab:"

    static func string(for id: UUID) -> String { prefix + id.uuidString }

    static func tabID(from string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}

/// Drops on a terminal tab: the dragged tab moves to the target's index. Shows the indicator while over it.
private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    let targetIndex: Int
    @Binding var dropTargetID: UUID?
    @Binding var draggingTabID: UUID?
    let move: @MainActor (UUID, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetID = nil
        draggingTabID = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let index = targetIndex
        let move = move
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString, let id = TabDragPayload.tabID(from: string as String) else { return }
            Task { @MainActor in move(id, index) }
        }
        return true
    }
}

/// The accent bar shown at the edge of the tab where a dragged tab will land.
private struct DropIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Theme.accent)
            .frame(width: 3, height: 26)
            .allowsHitTesting(false)
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

            Text(tab.displayTitle.isEmpty ? "Untitled host" : tab.displayTitle)
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
