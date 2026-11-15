import Foundation
import Observation
import CoreModels

/// The Snippets screen (and the terminal's snippets panel): snippets grouped by package, search,
/// and edits that save at once through `LocalVault.saveNow` (they sync). Every read comes from the
/// vault. Names and package names are trimmed; a blank package means none. Every change is
/// idempotent: writing what is stored saves nothing. Missing or deleted ids are ignored.
@MainActor @Observable
public final class SnippetsViewModel {
    /// Filters `sections` by name or script (case-insensitive, surrounding spaces ignored).
    public var searchText = ""

    @ObservationIgnored private let vault: LocalVault
    /// Packages made with "New snippet package" that no snippet uses yet. Kept for this view model's
    /// life only: a package exists in the vault only through its snippets.
    private var addedPackages: Set<String> = []

    public init(vault: LocalVault) {
        self.vault = vault
    }

    public struct Section: Identifiable {
        /// nil = the unpackaged snippets ("Snippets").
        public let package: String?
        public let snippets: [Snippet]
        public var id: String { package ?? "" }
    }

    private var all: [Snippet] {
        _ = vault.revision
        return vault.all(Snippet.self)
    }

    private var needle: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The unpackaged snippets first, then each package A–Z; snippets A–Z within each. Only matching
    /// snippets while searching, and sections without any are left out, except packages made with
    /// `addPackage` that no snippet uses yet, shown empty when not searching.
    public var sections: [Section] {
        let needle = self.needle
        let matching = all
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle)
                      || $0.script.localizedCaseInsensitiveContains(needle) }
            .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
        let grouped = Dictionary(grouping: matching) { $0.package }
        var result: [Section] = []
        if let loose = grouped[nil] { result.append(Section(package: nil, snippets: loose)) }
        let names = needle.isEmpty ? packages : grouped.keys.compactMap { $0 }.sorted(by: Self.packageOrder)
        for name in names {
            result.append(Section(package: name, snippets: grouped[name] ?? []))
        }
        return result
    }

    /// Every package in use (plus those added with `addPackage`), distinct, A–Z. Not filtered by search.
    public var packages: [String] {
        let used = Set(all.compactMap(\.package))
        return used.union(addedPackages).sorted(by: Self.packageOrder)
    }

    /// The stored snippet; nil when missing or deleted.
    public func snippet(_ id: UUID) -> Snippet? {
        _ = vault.revision
        return vault.get(Snippet.self, id: id)
    }

    /// "New snippet package": shows an empty package (until snippets move into it). Returns the
    /// trimmed name, or nil when it is blank.
    @discardableResult
    public func addPackage(_ name: String) -> String? {
        guard let name = Self.package(name) else { return nil }
        addedPackages.insert(name)
        return name
    }

    @discardableResult
    public func create(name: String, script: String, package: String?) -> Snippet {
        vault.saveNow(Snippet(name: Self.trimmed(name), script: script, package: package.flatMap(Self.package)))
    }

    /// nil = leave unchanged; `package: .some(nil)` removes the snippet from its package.
    public func update(_ id: UUID, name: String?, script: String?, package: String??) {
        change(id) { snippet in
            if let name { snippet.name = Self.trimmed(name) }
            if let script { snippet.script = script }
            if let package { snippet.package = package.flatMap(Self.package) }
        }
    }

    public func move(_ ids: [UUID], toPackage package: String?) {
        let target = package.flatMap(Self.package)
        for id in ids { change(id) { $0.package = target } }
    }

    /// A copy named "<name> copy" with the same script, package and saved targets.
    @discardableResult
    public func duplicate(_ id: UUID) -> Snippet? {
        guard let source = vault.get(Snippet.self, id: id) else { return nil }
        return vault.saveNow(Snippet(name: "\(source.name) copy", script: source.script, package: source.package,
                                     targetHostIDs: source.targetHostIDs))
    }

    /// Deletes it (a tombstone that syncs). Hosts that use it as their startup snippet keep the id; a
    /// missing snippet runs nothing.
    public func delete(_ id: UUID) {
        change(id) { $0.deleted = true }
    }

    /// "Save targets": the hosts to preselect next time, duplicates dropped (first kept); nil or empty
    /// clears them.
    public func saveTargets(_ id: UUID, hostIDs: [UUID]?) {
        var seen: Set<UUID> = []
        let unique = (hostIDs ?? []).filter { seen.insert($0).inserted }
        change(id) { $0.targetHostIDs = unique.isEmpty ? nil : unique }
    }

    /// Snippets that can be a startup snippet: those without placeholders, A–Z.
    public func startupCandidates() -> [Snippet] {
        all.filter { !SnippetTemplate($0.script).hasPlaceholders }
            .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
    }

    // MARK: Helpers

    private func change(_ id: UUID, _ edit: (inout Snippet) -> Void) {
        guard var snippet = vault.get(Snippet.self, id: id) else { return }
        let before = snippet
        edit(&snippet)
        if snippet != before { vault.saveNow(snippet) }
    }

    nonisolated private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A package name as stored: trimmed; blank = none.
    nonisolated private static func package(_ name: String) -> String? {
        let name = trimmed(name)
        return name.isEmpty ? nil : name
    }

    nonisolated static func packageOrder(_ a: String, _ b: String) -> Bool {
        switch a.localizedCaseInsensitiveCompare(b) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a < b
        }
    }

    nonisolated static func ordered(_ a: String, _ aID: UUID, _ b: String, _ bID: UUID) -> Bool {
        switch a.localizedCaseInsensitiveCompare(b) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: aID.uuidString < bID.uuidString
        }
    }
}
