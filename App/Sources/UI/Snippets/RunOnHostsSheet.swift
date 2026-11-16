import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// "Run on hosts…": a searchable host list with checkboxes (grouped by group), "Save targets", Run.
/// A snippet with placeholders shows `PlaceholderForm` first; Run then hands over the filled command.
/// Starts from the snippet's saved targets, if any.
struct RunOnHostsSheet: View {
    let vault: LocalVault
    let snippet: Snippet
    /// The chosen hosts (in list order), the command to type, and whether to save the targets.
    let onRun: (_ hostIDs: [UUID], _ text: String, _ saveTargets: Bool) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selected: Set<UUID>
    @State private var saveTargets: Bool
    /// Hosts chosen; the placeholder form is showing.
    @State private var fillingIn = false
    @FocusState private var searchFocused: Bool

    init(vault: LocalVault, snippet: Snippet,
         onRun: @escaping (_ hostIDs: [UUID], _ text: String, _ saveTargets: Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.vault = vault
        self.snippet = snippet
        self.onRun = onRun
        self.onCancel = onCancel
        _selected = State(initialValue: Set(snippet.targetHostIDs ?? []))
        _saveTargets = State(initialValue: snippet.targetHostIDs != nil)
    }

    private var template: SnippetTemplate { SnippetTemplate(snippet.script) }

    var body: some View {
        if fillingIn {
            PlaceholderForm(template: template, actionTitle: runTitle,
                            onSubmit: { text in run(text: text) },
                            onCancel: { fillingIn = false })
        } else {
            hostPicker
        }
    }

    // MARK: Host picker

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run \u{201C}\(SnippetCardView.displayName(of: snippet))\u{201D} on hosts")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search hosts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.searchFieldBackground)
            }

            hostList
                .frame(height: 300)

            HStack(spacing: 12) {
                Toggle("Save targets", isOn: $saveTargets)
                    .toggleStyle(.checkbox)
                    .help("Remember these hosts for this snippet")
                Spacer(minLength: 0)
                Text(selectionSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(allVisibleSelected ? "Deselect all" : "Select all", action: toggleAllVisible)
                    .disabled(visibleHostIDs.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: proceed)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenHostIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var hostList: some View {
        let sections = self.sections
        if sections.isEmpty {
            Text(allHosts.isEmpty ? "No hosts yet" : "No matching hosts")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.cardBackground)
                }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                            ForEach(section.hosts) { host in
                                HostCheckRow(host: host, isOn: selected.contains(host.id)) {
                                    toggle(host.id)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.cardBackground)
            }
        }
    }

    // MARK: Data

    private struct HostSection: Identifiable {
        let id: String
        let title: String
        let hosts: [SavedHost]
    }

    private var allHosts: [SavedHost] {
        vault.all(SavedHost.self)
    }

    /// Hosts matching the search, by group ("No group" first, then group paths A–Z), labels A–Z.
    private var sections: [HostSection] {
        let groups = Dictionary(vault.all(HostGroup.self).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = allHosts.filter { host in
            needle.isEmpty
                || host.label.localizedCaseInsensitiveContains(needle)
                || host.address.localizedCaseInsensitiveContains(needle)
        }
        let byGroup = Dictionary(grouping: matching) { host -> UUID? in
            host.groupID.flatMap { groups[$0] == nil ? nil : $0 }
        }
        let sections = byGroup.map { groupID, hosts in
            HostSection(
                id: groupID?.uuidString ?? "",
                title: groupID.map { Self.path(of: $0, in: groups) } ?? "No group",
                hosts: hosts.sorted { Self.hostName($0).localizedStandardCompare(Self.hostName($1)) == .orderedAscending }
            )
        }
        return sections.sorted { a, b in
            if a.id.isEmpty != b.id.isEmpty { return a.id.isEmpty }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// "Parent › Child" (guarding against cycles).
    private static func path(of groupID: UUID, in groups: [UUID: HostGroup]) -> String {
        var names: [String] = []
        var seen: Set<UUID> = []
        var current = groups[groupID]
        while let group = current, seen.insert(group.id).inserted {
            names.insert(group.name.isEmpty ? "Untitled group" : group.name, at: 0)
            current = group.parentID.flatMap { groups[$0] }
        }
        return names.joined(separator: " \u{203A} ")
    }

    static func hostName(_ host: SavedHost) -> String {
        if !host.label.isEmpty { return host.label }
        return host.address.isEmpty ? "Untitled host" : host.address
    }

    private var visibleHostIDs: [UUID] {
        sections.flatMap { $0.hosts.map(\.id) }
    }

    private var allVisibleSelected: Bool {
        let visible = visibleHostIDs
        return !visible.isEmpty && visible.allSatisfy(selected.contains)
    }

    /// Checked hosts that still exist, in list order (search ignored: hidden checked hosts still run).
    private var chosenHostIDs: [UUID] {
        let searchless = RunOnHostsSheet.ordered(allHosts, groups: vault.all(HostGroup.self))
        return searchless.filter(selected.contains)
    }

    /// Every host in the order the list shows them without a search.
    private static func ordered(_ hosts: [SavedHost], groups: [HostGroup]) -> [UUID] {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return hosts
            .map { host -> (String, String, UUID) in
                let groupKey = host.groupID.flatMap { byID[$0] == nil ? nil : $0 }.map { path(of: $0, in: byID) }
                // "No group" sorts first.
                return (groupKey.map { "1" + $0 } ?? "0", hostName(host), host.id)
            }
            .sorted { a, b in
                if a.0 != b.0 { return a.0.localizedStandardCompare(b.0) == .orderedAscending }
                return a.1.localizedStandardCompare(b.1) == .orderedAscending
            }
            .map(\.2)
    }

    private var selectionSummary: String {
        let count = chosenHostIDs.count
        switch count {
        case 0: return "No hosts selected"
        case 1: return "1 host selected"
        default: return "\(count) hosts selected"
        }
    }

    private var runTitle: String {
        let count = chosenHostIDs.count
        return count == 1 ? "Run on 1 host" : "Run on \(count) hosts"
    }

    // MARK: Actions

    private func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func toggleAllVisible() {
        if allVisibleSelected {
            selected.subtract(visibleHostIDs)
        } else {
            selected.formUnion(visibleHostIDs)
        }
    }

    /// Run: the placeholder form first when the script asks for values.
    private func proceed() {
        guard !chosenHostIDs.isEmpty else { return }
        if template.hasPlaceholders {
            fillingIn = true
        } else {
            run(text: snippet.script)
        }
    }

    private func run(text: String) {
        let hostIDs = chosenHostIDs
        guard !hostIDs.isEmpty else { return }
        onRun(hostIDs, text, saveTargets)
    }
}

/// A checkbox row for one host: name and address.
private struct HostCheckRow: View {
    let host: SavedHost
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Theme.accent : Color.secondary)
                Text(RunOnHostsSheet.hostName(host))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if !host.label.isEmpty && !host.address.isEmpty {
                    Text(host.address)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
