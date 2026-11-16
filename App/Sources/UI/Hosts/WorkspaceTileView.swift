import SwiftUI
import AppCore
import SwiftSSHUI

/// A saved workspace on the Hosts screen, styled like a host card: a teal split-view badge, the name
/// and "3 terminals · Split view". Click selects, double-click opens, the pencil edits.
struct WorkspaceTileView: View {
    let template: WorkspaceTemplate
    let isSelected: Bool
    var onEdit: (() -> Void)? = nil

    var body: some View {
        CardRow(title: template.name.isEmpty ? "Workspace" : template.name, subtitle: template.summary,
                isSelected: isSelected, onEdit: onEdit) {
            SymbolBadge(symbol: template.viewMode == .split ? "rectangle.split.2x2.fill" : "rectangle.leadinghalf.filled",
                        background: Theme.workspaceBadge)
        }
    }
}

extension Theme {
    /// Saved workspaces' badge (teal), apart from hosts' OS colours and groups' blue.
    static let workspaceBadge = Color(hex: "#0D9488")
}
