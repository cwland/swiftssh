import SwiftUI
import AppKit
import AppCore
import SwiftSSHUI

/// The Known Hosts screen: search bar, a summary toolbar, and the trusted server keys as cards in one
/// section per host:port (one card per key). A click selects a key, ⌘-click selects several; the
/// toolbar and right-click remove them. Each section's trash removes every key of that address.
/// All data goes through `KnownHostsViewModel`.
struct KnownHostsView: View {
    @Bindable var model: KnownHostsViewModel

    @State private var selection: Set<UUID> = []
    /// What the confirmation removes; kept after the dialog closes so its action can read it.
    @State private var pendingRemoval: Removal?
    @State private var showRemove = false

    /// What the confirmation is about.
    private enum Removal {
        case keys([UUID])
        case host(hostPort: String, address: String, keyCount: Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar
            // Computed once per render and passed down: `model.sections` decodes every record.
            let sections = model.sections
            let visibleIDs = sections.flatMap(\.rows).map(\.id)
            toolbar(selected: selectedIDs(in: visibleIDs))
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(sections) { section in
                            sectionView(section, visibleIDs: visibleIDs)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.contentBackground)
        .confirmationDialog(removalTitle, isPresented: $showRemove, titleVisibility: .visible) {
            Button(removalButtonTitle, role: .destructive) {
                confirmRemoval()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    // MARK: Selection

    /// Selected keys that still exist (another Mac may have removed one).
    private func selectedIDs(in visibleIDs: [UUID]) -> [UUID] {
        visibleIDs.filter(selection.contains)
    }

    /// A click selects the key; ⌘-click adds or removes it from the selection.
    private func click(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        } else {
            selection = [id]
        }
    }

    /// What a right-click Remove applies to: the whole selection when the card is part of it,
    /// otherwise just the card.
    private func actionTargets(for id: UUID, visibleIDs: [UUID]) -> [UUID] {
        let selected = selectedIDs(in: visibleIDs)
        return selection.contains(id) && selected.count > 1 ? selected : [id]
    }

    // MARK: Layout

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find by address, key type, fingerprint or saved host\u{2026}", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.searchFieldBackground)
        }
    }

    private func toolbar(selected: [UUID]) -> some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if !selected.isEmpty {
                Text("\(selected.count) selected")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("Deselect") { selection = [] }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    confirm(.keys(selected))
                } label: {
                    Label(selected.count == 1 ? "Remove Key" : "Remove \(selected.count) Keys",
                          systemImage: "trash")
                }
            }
        }
        .frame(minHeight: 28)
    }

    /// "3 keys for 2 hosts" (search ignored).
    private var summary: String {
        let keys = model.keyCount
        let hosts = model.hostCount
        guard keys > 0 else { return "" }
        return "\(keys) \(keys == 1 ? "key" : "keys") for \(hosts) \(hosts == 1 ? "host" : "hosts")"
    }

    private func sectionView(_ section: KnownHostsViewModel.Section, visibleIDs: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section)
            VStack(spacing: 8) {
                ForEach(section.rows) { row in
                    card(for: row, visibleIDs: visibleIDs)
                }
            }
        }
    }

    private func sectionHeader(_ section: KnownHostsViewModel.Section) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.address)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(Self.usedByText(section.usedBy))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Self.usedByText(section.usedBy))
            Spacer(minLength: 8)
            Button {
                confirm(.host(hostPort: section.hostPort, address: section.address,
                              keyCount: model.keyCount(hostPort: section.hostPort)))
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove all keys for \(section.address)")
            .accessibilityLabel("Remove all keys for \(section.address)")
        }
    }

    private func card(for row: KnownHostsViewModel.Row, visibleIDs: [UUID]) -> some View {
        KnownHostCard(row: row, isSelected: selection.contains(row.id)) {
            confirm(.keys([row.id]))
        }
        .onTapGesture { click(row.id) }
        .contextMenu {
            Button("Copy Fingerprint") { copy(row.fingerprint) }
            Divider()
            let targets = actionTargets(for: row.id, visibleIDs: visibleIDs)
            Button(targets.count == 1 ? "Remove" : "Remove \(targets.count) Keys", role: .destructive) {
                confirm(.keys(targets))
            }
            Button("Remove All Keys for \(row.address)", role: .destructive) {
                confirm(.host(hostPort: row.hostPort, address: row.address,
                              keyCount: model.keyCount(hostPort: row.hostPort)))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if model.keyCount == 0 {
                Text("No known hosts yet")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text("The first time you connect to a server, SwiftSSH shows its host key and asks whether to trust it. Trusted keys are kept here and checked on every later connection, so you are warned if a server\u{2019}s key changes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            } else {
                Text("No matching known hosts")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Removal

    private var removalTitle: String {
        guard let pendingRemoval else { return "" }
        return switch pendingRemoval {
        case .keys(let ids) where ids.count > 1: "Remove \(ids.count) keys?"
        case .host(_, let address, _): "Remove all keys for \(address)?"
        default: "Remove this key?"
        }
    }

    private var removalButtonTitle: String {
        guard let pendingRemoval else { return "" }
        return switch pendingRemoval {
        case .keys(let ids) where ids.count > 1: "Remove \(ids.count) Keys"
        case .host(_, _, let count) where count > 1: "Remove \(count) Keys"
        default: "Remove Key"
        }
    }

    private var removalMessage: String {
        guard let pendingRemoval else { return "" }
        switch pendingRemoval {
        case .keys(let ids):
            if ids.count == 1, let id = ids.first, let row = model.row(id) {
                return "The \(row.keyType) key for \(row.address) is removed from this vault. The next connection to \(row.address) will ask you to trust its key again."
            }
            if ids.count == 1 {
                // The key's row is gone (another Mac removed it while the dialog was open).
                return "This key is removed from this vault. The next connection to its server will ask you to trust its key again."
            }
            return "They are removed from this vault. The next connection to each of these servers will ask you to trust its key again."
        case .host(_, let address, let count):
            let keys = count == 1 ? "Its key is" : "Its \(count) keys are"
            return "\(keys) removed from this vault. The next connection to \(address) will ask you to trust its key again."
        }
    }

    private func confirm(_ removal: Removal) {
        pendingRemoval = removal
        showRemove = true
    }

    private func confirmRemoval() {
        guard let removal = pendingRemoval else { return }
        switch removal {
        case .keys(let ids):
            model.remove(ids)
            selection.subtract(ids)
        case .host(let hostPort, _, _):
            // Removed keys drop out of `selectedIDs` on their own.
            model.removeAll(hostPort: hostPort)
        }
        // `pendingRemoval` stays set: clearing it would empty the dialog's text while it animates out.
        // The next `confirm` overwrites it.
    }

    // MARK: Helpers

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "Used by NAS, NAS alt" or "No saved host uses this address".
    static func usedByText(_ hosts: [KnownHostsViewModel.SavedHostRef]) -> String {
        hosts.isEmpty ? "No saved host uses this address"
                      : "Used by " + hosts.map(\.label).joined(separator: ", ")
    }
}

/// One trusted key: a shield badge, the key type and its SHA256 fingerprint (monospaced), the date it
/// was first trusted, and a trash button (shown while hovered or selected).
private struct KnownHostCard: View {
    let row: KnownHostsViewModel.Row
    let isSelected: Bool
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.cardPadding) {
            SymbolBadge(symbol: "checkmark.shield.fill", background: Theme.knownHostBadge)
                .frame(width: Theme.cardBadgeSize, height: Theme.cardBadgeSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.keyType)
                    .font(.system(size: Theme.cardTitleFontSize))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(row.fingerprint)
                    .font(.system(size: Theme.cardSubtitleFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.fingerprint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text("First seen \(row.firstSeenText)")
                .font(.system(size: Theme.cardSubtitleFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .allowsHitTesting(isHovering || isSelected)
            .help("Remove this key")
            .accessibilityLabel("Remove the \(row.keyType) key for \(row.address)")
        }
        .padding(.horizontal, Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

extension Theme {
    /// The known-host card badge: a green that reads as "trusted".
    static let knownHostBadge = Color(hex: "#16A34A")
}
