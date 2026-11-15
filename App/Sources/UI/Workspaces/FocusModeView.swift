import SwiftUI
import UniformTypeIdentifiers
import AppCore
import CoreModels

/// A workspace in Focus mode: on the left the list "Terminals • N" (OS badge, name, "ssh, <user>",
/// status dot; the selected row is highlighted and has × to close it; rows drag to reorder), with
/// "Back to Split view" (⌘⇧M) and Broadcast (⌘B) buttons at the right of its header; on the right the selected pane's terminal,
/// which is also the input target while broadcasting. Switching panes or modes never interrupts a
/// session: only the selected pane's terminal view is hosted, the others keep running in
/// `TerminalViewStore`.
///
/// Created by `WorkspaceView`, which supplies the terminal for a pane id (its `TerminalTabView`
/// with drop zone and borders) and the shared pane actions.
struct FocusModeView<Terminal: View>: View {
    let workspace: Workspace
    let sessions: SessionManager
    let vault: LocalVault
    let actions: PaneActions
    /// The pane being dragged (a row here or a header in Split view); shared with `WorkspaceView`.
    @Binding var draggingPaneID: UUID?
    /// Starts dragging a pane: records it and returns its payload.
    let beginPaneDrag: (UUID) -> NSItemProvider
    /// A row dropped on another row's upper (`.top`) or lower (`.bottom`) half.
    let movePane: @MainActor (UUID, UUID, DropEdge) -> Void
    /// The selected pane's terminal.
    @ViewBuilder let terminal: (UUID) -> Terminal

    static var listWidth: CGFloat { 240 }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: Self.listWidth)
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
            if let id = selectedPaneID {
                terminal(id)
                    .id(id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Theme.contentBackground
            }
        }
    }

    /// The workspace's focused pane, or its first one if that is gone.
    private var selectedPaneID: UUID? {
        let ids = workspace.paneIDs
        return ids.contains(workspace.focusedPaneID) ? workspace.focusedPaneID : ids.first
    }

    // MARK: List

    private var list: some View {
        let ids = workspace.paneIDs
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Terminals \u{2022} \(ids.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // The reverse of the pane header's Focus mode button (arrows out → arrows in).
                HeaderButton(symbol: "arrow.down.right.and.arrow.up.left",
                             help: "Back to Split view \u{2318}\u{21E7}M",
                             label: "Back to Split view",
                             action: { actions.enterSplitView() })
                HeaderButton(symbol: "dot.radiowaves.left.and.right",
                             isOn: workspace.isBroadcasting,
                             help: workspace.isBroadcasting ? "Stop broadcasting input (\u{2318}B)" : "Broadcast input \u{2318}B",
                             label: workspace.isBroadcasting ? "Stop broadcasting input" : "Broadcast input",
                             action: { actions.toggleBroadcast() })
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(ids, id: \.self) { id in
                        if let tab = sessions.tabs.first(where: { $0.id == id }) {
                            row(tab)
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(Theme.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminals")
    }

    private func row(_ tab: TerminalTab) -> some View {
        let id = tab.id
        let isIncluded = !workspace.excludedFromBroadcast.contains(id)
        return FocusModeRow(
            tab: tab,
            subtitle: workspace.isBroadcasting && !isIncluded ? "not broadcasting" : PaneLabel.subtitle(tab, vault: vault),
            status: workspace.status(of: id),
            isSelected: id == selectedPaneID,
            close: { actions.close(id) }
        )
        .onTapGesture { actions.focus(id) }
        .onDrag { beginPaneDrag(id) }
        .modifier(RowDropTarget(rowID: id, draggingPaneID: $draggingPaneID, movePane: movePane))
        .contextMenu {
            PaneContextMenu(paneID: id, isIncludedInBroadcast: isIncluded, actions: actions)
        }
    }
}

/// One row of the Focus mode list.
struct FocusModeRow: View {
    let tab: TerminalTab
    let subtitle: String
    let status: PaneStatus
    let isSelected: Bool
    let close: () -> Void

    static let height: CGFloat = 48

    var body: some View {
        HStack(spacing: 10) {
            BadgeView(badge: tab.badge, size: 28)
                .opacity(PaneLabel.isLive(tab) ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(PaneLabel.title(tab))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusDot(status: status)
            if isSelected {
                HeaderButton(symbol: "xmark",
                             help: "Close this terminal (ends its session)",
                             label: "Close terminal",
                             action: close)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: Theme.sidebarRowCornerRadius, style: .continuous)
                .fill(isSelected ? Theme.sidebarSelection : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.sidebarRowCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Reordering rows: a pane dropped on a row's upper half lands before it, on the lower half after
/// it (`movePane(dragged, row, .top / .bottom)`). An accent line shows where.
private struct RowDropTarget: ViewModifier {
    let rowID: UUID
    @Binding var draggingPaneID: UUID?
    let movePane: @MainActor (UUID, UUID, DropEdge) -> Void

    @State private var edge: DropEdge?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                if edge != nil {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent)
                        .frame(height: 3)
                        .offset(y: edge == .bottom ? 2 : -2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.text], delegate: RowDropDelegate(rowID: rowID, height: FocusModeRow.height,
                                                           draggingPaneID: $draggingPaneID, edge: $edge,
                                                           movePane: movePane))
    }
}

private struct RowDropDelegate: DropDelegate {
    let rowID: UUID
    let height: CGFloat
    @Binding var draggingPaneID: UUID?
    @Binding var edge: DropEdge?
    let movePane: @MainActor (UUID, UUID, DropEdge) -> Void

    /// Only a pane drag (started in this workspace) reorders; the row itself is no target.
    private var isPaneDrag: Bool {
        guard let draggingPaneID else { return false }
        return draggingPaneID != rowID
    }

    private func landingEdge(for info: DropInfo) -> DropEdge {
        info.location.y < height / 2 ? .top : .bottom
    }

    func validateDrop(info: DropInfo) -> Bool {
        isPaneDrag && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard isPaneDrag else { return }
        edge = landingEdge(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isPaneDrag else { return DropProposal(operation: .forbidden) }
        let new = landingEdge(for: info)
        if edge != new { edge = new }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        edge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let landing = edge ?? landingEdge(for: info)
        edge = nil
        guard isPaneDrag else { return false }
        let target = rowID
        let movePane = movePane
        return WorkspaceDragPayload.load(from: info.itemProviders(for: [.text])) { payload in
            guard case .pane(let paneID) = payload else { return }
            movePane(paneID, target, landing)
        }
    }
}
