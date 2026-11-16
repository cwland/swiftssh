import Foundation
import Observation
import CoreModels

/// Settings → Recently Deleted: hosts, host groups and snippets that were deleted (on this Mac or
/// another), newest first, with Restore and Delete Permanently, and Empty for all of them.
///
/// A deleted record is a tombstone that still holds its details, so it can come back: restoring saves
/// it again as a newer change, which syncs to the other Macs. Deleting permanently wipes the details
/// but keeps the tombstone, so no other Mac can bring the record back with an older copy.
///
/// Restore and Delete Permanently take any listed id (ids are unique across record types).
@MainActor @Observable
public final class RecentlyDeletedViewModel {
    private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    /// Deleted hosts that still have their details, most recently deleted first.
    public var deletedHosts: [SavedHost] {
        Self.newestFirst(vault.deletedRecords(SavedHost.self).filter { !Self.isWiped($0) })
    }

    /// Deleted host groups that still have their details, most recently deleted first. A group comes
    /// back without the hosts and subgroups it had: deleting it moved them up a level.
    public var deletedGroups: [HostGroup] {
        Self.newestFirst(vault.deletedRecords(HostGroup.self).filter { !Self.isWiped($0) })
    }

    /// Deleted snippets that still have their details, most recently deleted first.
    public var deletedSnippets: [Snippet] {
        Self.newestFirst(vault.deletedRecords(Snippet.self).filter { !Self.isWiped($0) })
    }

    /// How many records are listed (all sections).
    public var count: Int {
        deletedHosts.count + deletedGroups.count + deletedSnippets.count
    }

    public var isEmpty: Bool { count == 0 }

    /// Brings the record back as it was. A host whose group no longer exists, or a group whose parent
    /// no longer exists, comes back at the top level. A snippet keeps its snippet group name (stored as
    /// `package`), which shows that group again even if no other snippet is in it. Unknown, live or
    /// wiped ids are ignored.
    public func restore(_ id: UUID) async throws {
        if var host = deletedHosts.first(where: { $0.id == id }) {
            host.deleted = false
            if let groupID = host.groupID, vault.get(HostGroup.self, id: groupID) == nil {
                host.groupID = nil
            }
            try await vault.save(host)
        } else if var group = deletedGroups.first(where: { $0.id == id }) {
            group.deleted = false
            if let parentID = group.parentID, vault.get(HostGroup.self, id: parentID) == nil {
                group.parentID = nil
            }
            try await vault.save(group)
        } else if var snippet = deletedSnippets.first(where: { $0.id == id }) {
            snippet.deleted = false
            try await vault.save(snippet)
        }
    }

    /// Wipes the record's details; the deletion itself stays (and syncs). Only deleted records are
    /// touched.
    public func deletePermanently(_ id: UUID) async throws {
        if vault.deletedRecords(SavedHost.self).contains(where: { $0.id == id }) {
            var wiped = SavedHost(id: id, label: "", address: "")
            wiped.deleted = true
            try await vault.save(wiped)
        } else if vault.deletedRecords(HostGroup.self).contains(where: { $0.id == id }) {
            try await vault.save(HostGroup(id: id, name: "", deleted: true))
        } else if vault.deletedRecords(Snippet.self).contains(where: { $0.id == id }) {
            try await vault.save(Snippet(id: id, name: "", script: "", deleted: true))
        }
    }

    /// Deletes every listed host, group and snippet permanently.
    public func empty() async throws {
        let ids = deletedHosts.map(\.id) + deletedGroups.map(\.id) + deletedSnippets.map(\.id)
        for id in ids {
            try await deletePermanently(id)
        }
    }

    /// Most recently deleted first; equal times (two deletions within a millisecond) keep the
    /// later-deleted one first.
    private static func newestFirst<M: SyncableModel>(_ records: [M]) -> [M] {
        records.enumerated()
            .sorted { a, b in
                a.element.updatedAt != b.element.updatedAt ? a.element.updatedAt > b.element.updatedAt
                                                           : a.offset > b.offset
            }
            .map(\.element)
    }

    /// A tombstone whose details were wiped (`deletePermanently`, or one that arrived without them).
    private static func isWiped(_ host: SavedHost) -> Bool {
        host.label.isEmpty && host.address.isEmpty
    }

    /// A wiped group: no name and no settings. (An unnamed group with no settings is left out too;
    /// there is nothing in it to restore.)
    private static func isWiped(_ group: HostGroup) -> Bool {
        group.name.isEmpty && group.parentID == nil && group.defaultIdentityID == nil
            && group.defaultPort == nil && group.defaultThemeID == nil && group.defaultTmuxSession == nil
            && group.startupSnippetID == nil
    }

    private static func isWiped(_ snippet: Snippet) -> Bool {
        snippet.name.isEmpty && snippet.script.isEmpty
    }
}
