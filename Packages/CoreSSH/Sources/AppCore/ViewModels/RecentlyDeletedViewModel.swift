import Foundation
import Observation
import CoreModels

/// Settings → Recently Deleted: hosts that were deleted (on this Mac or another), newest first, with
/// Restore and Delete Permanently.
///
/// A deleted host is a tombstone that still holds its details, so it can come back: restoring saves
/// it again as a newer change, which syncs to the other Macs. Deleting permanently wipes the details
/// but keeps the tombstone, so no other Mac can bring the host back with an older copy.
@MainActor @Observable
public final class RecentlyDeletedViewModel {
    private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    /// Deleted hosts that still have their details, most recently deleted first.
    public var deletedHosts: [SavedHost] {
        // Equal times (two deletions within a millisecond) keep the later-deleted one first.
        vault.deletedRecords(SavedHost.self)
            .filter { !Self.isWiped($0) }
            .enumerated()
            .sorted { a, b in
                a.element.updatedAt != b.element.updatedAt ? a.element.updatedAt > b.element.updatedAt
                                                           : a.offset > b.offset
            }
            .map(\.element)
    }

    /// Brings the host back as it was. A group that no longer exists is dropped (the host comes back
    /// at the top level).
    public func restore(_ id: UUID) async throws {
        guard var host = vault.deletedRecords(SavedHost.self).first(where: { $0.id == id }) else { return }
        host.deleted = false
        if let groupID = host.groupID, vault.get(HostGroup.self, id: groupID) == nil {
            host.groupID = nil
        }
        try await vault.save(host)
    }

    /// Wipes the host's details; the deletion itself stays (and syncs).
    public func deletePermanently(_ id: UUID) async throws {
        guard vault.deletedRecords(SavedHost.self).contains(where: { $0.id == id }) else { return }
        var wiped = SavedHost(id: id, label: "", address: "")
        wiped.deleted = true
        try await vault.save(wiped)
    }

    /// Deletes every listed host permanently.
    public func empty() async throws {
        for host in deletedHosts {
            try await deletePermanently(host.id)
        }
    }

    /// A tombstone whose details were wiped (`deletePermanently`, or one that arrived without them).
    private static func isWiped(_ host: SavedHost) -> Bool {
        host.label.isEmpty && host.address.isEmpty
    }
}
