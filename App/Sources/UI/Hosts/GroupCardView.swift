import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// A host group: folder symbol, name and "N hosts" (the shared `GroupCard`).
struct GroupCardView: View {
    let group: HostGroup
    let hostCount: Int
    var isSelected = false
    var onEdit: (() -> Void)? = nil

    var body: some View {
        GroupCard(name: group.name, hostCount: hostCount, isSelected: isSelected, onEdit: onEdit)
    }
}
