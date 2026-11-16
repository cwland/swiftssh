import SwiftUI
import AppKit

/// What drags into a terminal area carry: plain text (`NSString`, so the system drag pasteboard holds
/// it as `public.utf8-plain-text`), a prefix naming the kind, then the id. Text dragged in from
/// elsewhere has no prefix and is ignored by the drop zones.
///
/// - Tab: `swiftssh-tab:<UUID>` — the tab bar's own format (`TopBarView`'s private
///   `TabDragPayload` writes exactly this), so a tab dragged off the bar drops into a pane.
/// - Host: `swiftssh-host:<UUID>` — a saved host's card (Hosts screen). The card's
///   `.onDrag` returns `WorkspaceDragPayload.itemProvider(hostID:)`; dropping opens a new
///   connection to that host in the pane.
/// - Pane: `swiftssh-pane:<UUID>` — a pane's header (or a Focus mode row) of a workspace;
///   only drop zones of the same workspace accept it (they move the pane). A pane is never taken
///   for a tab, so it can't be dropped on the tab bar or onto a plain tab.
enum WorkspaceDragPayload: Equatable, Sendable {
    case tab(UUID)
    case host(UUID)
    case pane(UUID)

    static let tabPrefix = "swiftssh-tab:"
    static let hostPrefix = "swiftssh-host:"
    static let panePrefix = "swiftssh-pane:"

    /// The text this payload is dragged as.
    var string: String {
        switch self {
        case .tab(let id): Self.tabPrefix + id.uuidString
        case .host(let id): Self.hostPrefix + id.uuidString
        case .pane(let id): Self.panePrefix + id.uuidString
        }
    }

    /// nil for text that isn't one of ours.
    init?(string: String) {
        let prefixes: [(String, (UUID) -> WorkspaceDragPayload)] = [
            (Self.tabPrefix, { .tab($0) }),
            (Self.hostPrefix, { .host($0) }),
            (Self.panePrefix, { .pane($0) }),
        ]
        for (prefix, make) in prefixes where string.hasPrefix(prefix) {
            guard let id = UUID(uuidString: String(string.dropFirst(prefix.count))) else { return nil }
            self = make(id)
            return
        }
        return nil
    }

    /// The item provider for `.onDrag`.
    var itemProvider: NSItemProvider {
        NSItemProvider(object: string as NSString)
    }

    /// For a host card's `.onDrag` (W3: Hosts screen).
    static func itemProvider(hostID: UUID) -> NSItemProvider {
        WorkspaceDragPayload.host(hostID).itemProvider
    }

    /// For a terminal tab's `.onDrag` (same text as the tab bar writes).
    static func itemProvider(tabID: UUID) -> NSItemProvider {
        WorkspaceDragPayload.tab(tabID).itemProvider
    }

    /// Reads the first text item of a drop and hands the payload to `deliver` on the main actor;
    /// text that isn't ours is dropped silently. False when the drop carries no text.
    @discardableResult
    static func load(from providers: [NSItemProvider],
                     deliver: @escaping @MainActor (WorkspaceDragPayload) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString,
                  let payload = WorkspaceDragPayload(string: text as String) else { return }
            Task { @MainActor in deliver(payload) }
        }
        return true
    }
}

/// Clears drag state once the mouse button is up: a drag that is cancelled, or ends somewhere that
/// isn't a drop zone, gets no callback (the same watch the tab bar uses).
@MainActor
enum DragEndWatch {
    static func start(_ ended: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            var upTicks = 0
            // Two readings with the button up, so a drop being performed on mouse-up finishes first.
            while upTicks < 2 {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
                upTicks = NSEvent.pressedMouseButtons == 0 ? upTicks + 1 : 0
            }
            ended()
        }
    }
}
