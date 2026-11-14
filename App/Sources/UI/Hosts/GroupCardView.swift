import SwiftUI
import AppCore
import CoreModels

/// A host group: folder symbol, name and "N hosts".
struct GroupCardView: View {
    let group: HostGroup
    let hostCount: Int

    var body: some View {
        CardRow(title: group.name.isEmpty ? "Untitled group" : group.name,
                subtitle: hostCount == 1 ? "1 host" : "\(hostCount) hosts") {
            SymbolBadge(symbol: "folder.fill", background: Theme.accent.opacity(0.15), foreground: Theme.accent)
        }
    }
}
