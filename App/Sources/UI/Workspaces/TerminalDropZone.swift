import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore

/// Drop target over a terminal area (a workspace pane, Focus mode's terminal, or a plain terminal
/// tab): while a terminal tab, a host card or a pane is dragged over it, a green translucent highlight
/// covers only the half (left/right/top/bottom, by the cursor's nearest edge) where the new pane will
/// go; the rest of the terminal stays as it is. The drop reports the payload's id and that edge.
///
/// Usage (W3, on a plain tab's `TerminalTabView`):
/// ```swift
/// .terminalDropZone(onDropTab: { tabID, edge in … }, onDropHost: { hostID, edge in … })
/// ```
/// While hovering, the dragged text can't be read yet, so any text drag shows the overlay; the drop
/// itself only acts on our payloads (`WorkspaceDragPayload`) and ignores other text.
enum TerminalDropZone {
    /// Shown (instead of a highlight) when the workspace is full and only pane moves are accepted.
    static let fullMessage = "A workspace holds at most 16 terminals"

    /// The edge nearest to `point` (the area is split along its diagonals, so each edge owns a
    /// triangle); its half is where the drop lands.
    static func edge(for point: CGPoint, in size: CGSize) -> DropEdge {
        guard size.width > 0, size.height > 0 else { return .right }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        let horizontal = min(x, 1 - x)
        let vertical = min(y, 1 - y)
        if horizontal <= vertical {
            return x < 0.5 ? .left : .right
        }
        return y < 0.5 ? .top : .bottom
    }

    /// The half of `size` that `edge` names.
    static func halfRect(_ edge: DropEdge, in size: CGSize) -> CGRect {
        switch edge {
        case .left: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

extension View {
    /// Makes this terminal area a drop target for terminal tabs (`onDropTab`), host cards
    /// (`onDropHost`) and, when given, panes of the same workspace (`onDropPane`). Each closure gets
    /// the dropped id and the edge of this area it was dropped on.
    ///
    /// - `isEnabled`: false turns the zone off (no overlay, no drops).
    /// - `acceptsNewTerminals`: false (the workspace already has 16 panes) ignores tab and host drops
    ///   and says so in the overlay instead of highlighting; pane moves still work.
    /// - `isMovingPane`: a pane of this workspace is being dragged (its header): the landing half is
    ///   highlighted even when the workspace is full.
    /// - `isDragSource`: this area is the dragged pane itself; it refuses the drop.
    func terminalDropZone(isEnabled: Bool = true,
                          acceptsNewTerminals: Bool = true,
                          isMovingPane: Bool = false,
                          isDragSource: Bool = false,
                          onDropTab: @escaping @MainActor (UUID, DropEdge) -> Void,
                          onDropHost: @escaping @MainActor (UUID, DropEdge) -> Void,
                          onDropPane: (@MainActor (UUID, DropEdge) -> Void)? = nil) -> some View {
        modifier(TerminalDropZoneModifier(isEnabled: isEnabled,
                                          acceptsNewTerminals: acceptsNewTerminals,
                                          isMovingPane: isMovingPane,
                                          isDragSource: isDragSource,
                                          onDropTab: onDropTab,
                                          onDropHost: onDropHost,
                                          onDropPane: onDropPane))
    }
}

struct TerminalDropZoneModifier: ViewModifier {
    let isEnabled: Bool
    let acceptsNewTerminals: Bool
    let isMovingPane: Bool
    let isDragSource: Bool
    let onDropTab: @MainActor (UUID, DropEdge) -> Void
    let onDropHost: @MainActor (UUID, DropEdge) -> Void
    let onDropPane: (@MainActor (UUID, DropEdge) -> Void)?

    /// The half under the cursor while a drag is over the area; nil otherwise.
    @State private var hoverEdge: DropEdge?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
            .overlay {
                if let hoverEdge, isEnabled, !isDragSource {
                    TerminalDropZoneOverlay(edge: hoverEdge,
                                            message: isMovingPane || acceptsNewTerminals ? nil : TerminalDropZone.fullMessage)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoverEdge)
            // SwiftUI can skip `dropExited` (the panes rearrange mid-drag, or the dragged pane is the
            // one under the cursor), which would leave the overlay up. Once no mouse button is held
            // (two readings in a row, so a drop on mouse-up finishes first), the drag is over.
            .task(id: hoverEdge != nil) {
                guard hoverEdge != nil else { return }
                var upTicks = 0
                while upTicks < 2 {
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { return }
                    upTicks = NSEvent.pressedMouseButtons == 0 ? upTicks + 1 : 0
                }
                hoverEdge = nil
            }
            .onChange(of: isDragSource) { hoverEdge = nil }
            .onChange(of: isEnabled) { hoverEdge = nil }
            .onDrop(of: [.text], delegate: TerminalDropDelegate(
                isEnabled: isEnabled && !isDragSource,
                size: size,
                hoverEdge: $hoverEdge,
                perform: { payload, edge in
                    switch payload {
                    case .tab(let id):
                        if acceptsNewTerminals { onDropTab(id, edge) }
                    case .host(let id):
                        if acceptsNewTerminals { onDropHost(id, edge) }
                    case .pane(let id):
                        onDropPane?(id, edge)
                    }
                }
            ))
    }

}

private struct TerminalDropDelegate: DropDelegate {
    let isEnabled: Bool
    let size: CGSize
    @Binding var hoverEdge: DropEdge?
    let perform: @MainActor (WorkspaceDragPayload, DropEdge) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard isEnabled else { return }
        hoverEdge = TerminalDropZone.edge(for: info.location, in: size)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isEnabled else { return DropProposal(operation: .forbidden) }
        let edge = TerminalDropZone.edge(for: info.location, in: size)
        if hoverEdge != edge { hoverEdge = edge }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        hoverEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let edge = hoverEdge ?? TerminalDropZone.edge(for: info.location, in: size)
        hoverEdge = nil
        guard isEnabled else { return false }
        let perform = perform
        return WorkspaceDragPayload.load(from: info.itemProviders(for: [.text])) { payload in
            perform(payload, edge)
        }
    }
}

/// The overlay shown while a drag is over a terminal area: a green translucent box over the half where
/// the new pane goes. With a `message` (a full workspace refusing new terminals) only the message shows,
/// no highlight. The terminal is never dimmed. Never takes clicks.
struct TerminalDropZoneOverlay: View {
    let edge: DropEdge
    var message: String? = nil

    var body: some View {
        GeometryReader { proxy in
            let half = TerminalDropZone.halfRect(edge, in: proxy.size)
            ZStack(alignment: .topLeading) {
                if let message {
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .frame(maxWidth: max(proxy.size.width - 24, 0))
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.dropHighlight.opacity(0.25))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.dropHighlight.opacity(0.8), lineWidth: 2)
                        }
                        .frame(width: max(half.width - 8, 0), height: max(half.height - 8, 0))
                        .position(x: half.midX, y: half.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message ?? "Drop here to split")
    }
}
