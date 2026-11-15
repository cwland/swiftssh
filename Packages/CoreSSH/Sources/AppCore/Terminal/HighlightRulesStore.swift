import Foundation
import Observation
import CoreModels

/// Settings → Highlighting's list of custom rules, kept in the vault as the one
/// `TerminalHighlightRules` record (so it syncs to the user's other Macs, end-to-end encrypted).
///
/// The store exists before the vault is open (terminal views and Settings hold it from launch);
/// `attach(_:)` connects it once the vault is ready. Until then it has no rules and ignores edits.
/// It also ignores edits while `isReadOnly` (a list this version can't read).
/// Reading `rules` or `compiled` in an observation scope tracks the vault, so rules pulled from
/// another Mac reach observers (open terminals, the Settings pane) like local edits do.
@MainActor @Observable
public final class HighlightRulesStore {
    @ObservationIgnored private var vault: LocalVault?
    /// Bumped by `attach`, so observers of `rules` notice the vault arriving.
    private var vaultGeneration = 0
    @ObservationIgnored private var cachedCompiled = CompiledHighlightRules.empty

    public init(vault: LocalVault? = nil) {
        self.vault = vault
    }

    /// Connects the open vault (once per launch; attaching the same vault again does nothing).
    public func attach(_ vault: LocalVault) {
        guard self.vault !== vault else { return }
        self.vault = vault
        vaultGeneration += 1
    }

    /// False until the vault is open: the list can't be edited yet.
    public var isAvailable: Bool {
        _ = vaultGeneration
        return vault != nil
    }

    /// True when the vault holds a rules list this app version can't read (a newer version
    /// changed its shape): `rules` is empty and every edit is refused, so the list is never
    /// overwritten. Settings shows the pane read-only with a note to update the app.
    public var isReadOnly: Bool {
        _ = vaultGeneration
        guard let vault else { return false }
        return vault.hasLiveRecord(TerminalHighlightRules.recordType, id: TerminalHighlightRules.singletonID)
            && vault.get(TerminalHighlightRules.self, id: TerminalHighlightRules.singletonID) == nil
    }

    /// The rules in priority order (earlier wins where matches overlap).
    public var rules: [HighlightRule] {
        _ = vaultGeneration
        guard let vault else { return [] }
        _ = vault.revision
        return vault.get(TerminalHighlightRules.self, id: TerminalHighlightRules.singletonID)?.rules ?? []
    }

    /// `rules` compiled for matching; rebuilt only when the list changes.
    public var compiled: CompiledHighlightRules {
        let current = rules
        if cachedCompiled.rules != current {
            cachedCompiled = CompiledHighlightRules(rules: current)
        }
        return cachedCompiled
    }

    /// A blank rule for the editor: the first palette colour no rule uses yet (else the first).
    public func makeNewRule() -> HighlightRule {
        let used = Set(rules.map(\.rgbColor))
        let color = HighlightPalette.colors.first { !used.contains($0.color) }?.color ?? HighlightPalette.defaultColor
        return HighlightRule(pattern: "", color: color.hex)
    }

    /// Adds `rule` at the end (lowest priority); an existing id is replaced in place instead.
    public func add(_ rule: HighlightRule) {
        var list = rules
        if let index = list.firstIndex(where: { $0.id == rule.id }) {
            list[index] = rule
        } else {
            list.append(rule)
        }
        save(list)
    }

    /// Replaces the rule with `rule.id`; adds it at the end when it is no longer there (deleted on
    /// another Mac while being edited here).
    public func update(_ rule: HighlightRule) {
        add(rule)
    }

    public func delete(id: UUID) {
        var list = rules
        list.removeAll { $0.id == id }
        save(list)
    }

    public func setEnabled(_ isEnabled: Bool, id: UUID) {
        var list = rules
        guard let index = list.firstIndex(where: { $0.id == id }), list[index].isEnabled != isEnabled else { return }
        list[index].isEnabled = isEnabled
        save(list)
    }

    /// One place earlier (higher priority). Does nothing for the first rule.
    public func moveUp(id: UUID) {
        var list = rules
        guard let index = list.firstIndex(where: { $0.id == id }), index > 0 else { return }
        list.swapAt(index, index - 1)
        save(list)
    }

    /// One place later (lower priority). Does nothing for the last rule.
    public func moveDown(id: UUID) {
        var list = rules
        guard let index = list.firstIndex(where: { $0.id == id }), index < list.count - 1 else { return }
        list.swapAt(index, index + 1)
        save(list)
    }

    /// SwiftUI's `onMove` semantics: `destination` is an index in the list before the move.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = rules
        let valid = source.filter { $0 < list.count }
        guard !valid.isEmpty else { return }
        let moving = valid.map { list[$0] }
        let insertAt = destination - valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) { list.remove(at: index) }
        list.insert(contentsOf: moving, at: min(max(insertAt, 0), list.count))
        save(list)
    }

    private func save(_ list: [HighlightRule]) {
        guard let vault, !isReadOnly else { return }
        let existing = vault.get(TerminalHighlightRules.self, id: TerminalHighlightRules.singletonID)
        if let existing {
            guard existing.rules != list else { return }
        } else {
            guard !list.isEmpty else { return }
        }
        var record = existing ?? TerminalHighlightRules(rules: [])
        record.rules = list
        vault.saveNow(record)
    }
}
