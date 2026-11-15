import SwiftUI
import AppCore
import CoreModels

/// A workspace pane's title bar: OS badge, host name, "ssh, <user>", status dot, then Broadcast,
/// Focus mode and Close. Dragging it moves the pane (the drag is set up by `WorkspaceView`); its
/// right-click menu is `PaneContextMenu`. The buttons carry no key equivalents themselves (⌘B and
/// ⌘⇧M are menu commands); their tooltips name them.
struct PaneHeader: View {
    let tab: TerminalTab
    /// "ssh, <user>" (`PaneLabel.subtitle`).
    let subtitle: String
    let status: PaneStatus
    let isFocused: Bool
    /// The workspace is broadcasting input.
    let isBroadcasting: Bool
    /// This pane takes part when broadcasting (`excludedFromBroadcast` doesn't hold it).
    let isIncludedInBroadcast: Bool
    let toggleBroadcast: () -> Void
    /// This pane's own theme (the host keeps its theme; the workspace saves it).
    let changeTheme: () -> Void
    let enterFocusMode: () -> Void
    let close: () -> Void

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            BadgeView(badge: tab.badge, size: 18)
                .opacity(PaneLabel.isLive(tab) ? 1 : 0.5)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(PaneLabel.title(tab))
                    .font(.system(size: 12, weight: isFocused ? .semibold : .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            StatusDot(status: status)
            Spacer(minLength: 4)
            HeaderButton(symbol: "paintpalette",
                         help: "Theme for this terminal (its host keeps its own)",
                         label: "Change theme",
                         action: changeTheme)
            HeaderButton(symbol: "dot.radiowaves.left.and.right",
                         isOn: isBroadcasting && isIncludedInBroadcast,
                         help: isBroadcasting ? "Stop broadcasting input (\u{2318}B)" : "Broadcast input \u{2318}B",
                         label: isBroadcasting ? "Stop broadcasting input" : "Broadcast input",
                         action: toggleBroadcast)
            HeaderButton(symbol: "arrow.up.left.and.arrow.down.right",
                         help: "Focus mode \u{2318}\u{21E7}M",
                         label: "Focus mode",
                         action: enterFocusMode)
            HeaderButton(symbol: "xmark",
                         help: "Close this terminal (ends its session)",
                         label: "Close terminal",
                         action: close)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.contentBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(PaneLabel.title(tab)), \(subtitle)")
    }
}

/// A small borderless symbol button for pane headers and the Focus mode list.
struct HeaderButton: View {
    let symbol: String
    var isOn = false
    let help: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? Theme.accent : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? Theme.accent.opacity(0.15)
                              : (isHovering ? Color.primary.opacity(0.08) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Green = new output since the pane was last focused, yellow = waiting for input (host key or
/// password), red = failed or disconnected; nothing when idle.
struct StatusDot: View {
    let status: PaneStatus

    var body: some View {
        if let color = status.dotColor {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .help(status.helpText)
                .accessibilityLabel(status.helpText)
        }
    }
}

extension PaneStatus {
    var dotColor: Color? {
        switch self {
        case .none: nil
        case .newOutput: .green
        case .waitingForInput: .yellow
        case .failed: .red
        }
    }

    var helpText: String {
        switch self {
        case .none: ""
        case .newOutput: "New output"
        case .waitingForInput: "Waiting for input"
        case .failed: "Disconnected"
        }
    }
}

/// Labels shared by pane headers and Focus mode rows.
@MainActor
enum PaneLabel {
    static func title(_ tab: TerminalTab) -> String {
        tab.displayTitle.isEmpty ? "Untitled host" : tab.displayTitle
    }

    /// "ssh, <user>" for a saved host (its own username, else its identity's or its group's, as on
    /// the host cards); "ssh" when none is known (quick connect).
    static func subtitle(_ tab: TerminalTab, vault: LocalVault) -> String {
        _ = vault.revision
        guard let hostID = tab.savedHostID, let host = vault.get(SavedHost.self, id: hostID) else { return "ssh" }
        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        let username = CredentialResolution.resolve(host: host, directory: directory, vault: vault).username
        return username.map { "ssh, \($0)" } ?? "ssh"
    }

    static func isLive(_ tab: TerminalTab) -> Bool {
        if case .connected = tab.state { return true }
        return false
    }
}

/// The right-click menu of a pane (its header in Split view, its row in Focus mode).
struct PaneContextMenu: View {
    let paneID: UUID
    let isIncludedInBroadcast: Bool
    /// False at 16 panes: Split Right / Split Down are shown disabled.
    var canSplit = true
    let actions: PaneActions

    var body: some View {
        Button("Move to New Tab") { actions.popOut(paneID) }
        Button("Rename\u{2026}") { actions.rename(paneID) }
        Divider()
        // A new connection to the same host beside this pane, as the tab bar's menu does for a tab.
        Button("Split Right") { actions.split(paneID, .right) }
            .disabled(!canSplit)
        Button("Split Down") { actions.split(paneID, .bottom) }
            .disabled(!canSplit)
        Divider()
        if isIncludedInBroadcast {
            Button("Exclude from Broadcast") { actions.setIncludedInBroadcast(paneID, false) }
        } else {
            Button("Include in Broadcast") { actions.setIncludedInBroadcast(paneID, true) }
        }
        Divider()
        Button("Change Theme\u{2026}") { actions.changeTheme(paneID) }
        Button("Snippets\u{2026}") { actions.showSnippets(paneID) }
        Button("History\u{2026}") { actions.showHistory(paneID) }
        Divider()
        Button("Close") { actions.close(paneID) }
    }
}

/// What a pane's chrome can do; built by `WorkspaceView` for its panes and Focus mode rows.
struct PaneActions {
    let focus: @MainActor (UUID) -> Void
    let close: @MainActor (UUID) -> Void
    let popOut: @MainActor (UUID) -> Void
    /// Split Right / Split Down: a new connection to the pane's host on that side of it, focused.
    let split: @MainActor (UUID, DropEdge) -> Void
    /// Asks for the pane's tab title (the host keeps its name).
    let rename: @MainActor (UUID) -> Void
    let setIncludedInBroadcast: @MainActor (UUID, Bool) -> Void
    let changeTheme: @MainActor (UUID) -> Void
    let showSnippets: @MainActor (UUID) -> Void
    let showHistory: @MainActor (UUID) -> Void
    let toggleBroadcast: @MainActor () -> Void
    /// Focus mode with this pane as the large terminal.
    let enterFocusMode: @MainActor (UUID) -> Void
    let enterSplitView: @MainActor () -> Void
}
