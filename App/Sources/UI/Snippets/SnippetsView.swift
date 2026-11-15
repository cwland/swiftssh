import SwiftUI
import AppKit
import AppCore
import CoreModels

/// The Snippets screen: search bar, toolbar, snippet cards in package sections, and the snippet editor
/// on the right for the selected snippet. ⌘-click selects several (to move or remove them together);
/// drag cards onto a package's section header to move them there. Packages exist only through their
/// snippets. All data goes through `SnippetsViewModel`.
struct SnippetsView: View {
    @Bindable var model: SnippetsViewModel
    let vault: LocalVault
    let sessions: SessionManager
    /// Carries a snippet to select when another screen sends the user here (`snippetToSelect`).
    let navigation: AppNavigation

    @State private var selection: Set<UUID> = []
    /// The snippet whose "Run on hosts…" sheet is open.
    @State private var runSnippet: Snippet?
    @State private var newPackageRequest: NewPackageRequest?
    /// Snippets waiting for the "Remove" confirmation.
    @State private var pendingRemoval: [UUID] = []
    @State private var showRemove = false
    /// The section header a drag is over (`Section.id`).
    @State private var dropTargetID: String?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var errorTitle = "Something went wrong"

    /// "New package…": the snippets to move into it; none = create a new snippet there.
    private struct NewPackageRequest: Identifiable {
        let id = UUID()
        let snippetIDs: [UUID]
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let snippet = selectedSnippet {
                Divider()
                SnippetEditorPanel(
                    model: model,
                    snippet: snippet,
                    onClose: { selection = [] },
                    onRun: { runSnippet = snippet },
                    onDuplicate: { duplicate(snippet.id) },
                    onDelete: { confirmRemove([snippet.id]) },
                    onNewPackage: { newPackageRequest = NewPackageRequest(snippetIDs: [snippet.id]) }
                )
                .id(snippet.id)
                .transition(.move(edge: .trailing))
            } else if selectedIDs.count > 1 {
                Divider()
                multipleSelectionPanel
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: panelKey)
        .onAppear(perform: takeRequestedSelection)
        .onChange(of: navigation.snippetToSelect) { _, _ in takeRequestedSelection() }
        .background(Theme.contentBackground)
        .sheet(item: $runSnippet) { snippet in
            RunOnHostsSheet(vault: vault, snippet: snippet, onRun: { hostIDs, text, save in
                run(snippet, on: hostIDs, text: text, saveTargets: save)
            }, onCancel: {
                runSnippet = nil
            })
        }
        .sheet(item: $newPackageRequest) { request in
            NewPackageSheet(
                explanation: newPackageExplanation(for: request),
                existingPackages: model.packages,
                onCreate: { name in
                    newPackageRequest = nil
                    createPackage(name, for: request)
                },
                onCancel: { newPackageRequest = nil }
            )
        }
        .confirmationDialog(removalTitle, isPresented: $showRemove, titleVisibility: .visible) {
            Button(pendingRemoval.count == 1 ? "Remove snippet" : "Remove \(pendingRemoval.count) snippets",
                   role: .destructive) {
                remove(pendingRemoval)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
        .alert(errorTitle, isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: Selection

    /// Selected snippets that still exist (another device may have removed one).
    private var selectedIDs: [UUID] {
        allSnippetIDsInOrder.filter(selection.contains)
    }

    /// Selects the snippet another screen asked for (Edit / New Snippet from a terminal), once.
    private func takeRequestedSelection() {
        guard let id = navigation.snippetToSelect else { return }
        navigation.snippetToSelect = nil
        if model.snippet(id) != nil { selection = [id] }
    }

    /// The editor shows for a single selection.
    private var selectedSnippet: Snippet? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return vault.get(Snippet.self, id: id)
    }

    /// Changes when the right-hand panel changes (for its animation).
    private var panelKey: String {
        if let snippet = selectedSnippet { return snippet.id.uuidString }
        return selectedIDs.count > 1 ? "many" : ""
    }

    /// Every non-deleted snippet (vault order), search ignored.
    private var allSnippetIDsInOrder: [UUID] {
        vault.all(Snippet.self).map(\.id)
    }

    /// A click selects the snippet; ⌘-click adds or removes it from the selection.
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

    /// What a context-menu or drag action on this card applies to: the whole selection when the card is
    /// part of it, otherwise just the card.
    private func actionTargets(for id: UUID) -> [UUID] {
        selection.contains(id) && selectedIDs.count > 1 ? selectedIDs : [id]
    }

    // MARK: Layout

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar
            toolbar
            if model.sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(model.sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find a snippet by name or script\u{2026}", text: $model.searchText)
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("New Snippet") { createSnippet() }
                Button("New package\u{2026}") {
                    newPackageRequest = NewPackageRequest(snippetIDs: selectedIDs)
                }
            } label: {
                Label("New Snippet", systemImage: "plus")
            } primaryAction: {
                createSnippet()
            }
            .fixedSize()

            Spacer(minLength: 0)

            if selectedIDs.count > 1 {
                Text("\(selectedIDs.count) selected")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionView(_ section: SnippetsViewModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section)
            LazyVGrid(columns: Theme.cardGridColumns, spacing: Theme.cardSpacing) {
                ForEach(section.snippets) { snippet in
                    card(for: snippet)
                }
            }
        }
    }

    /// The section's title; also where cards are dropped to move them into its package.
    private func sectionHeader(_ section: SnippetsViewModel.Section) -> some View {
        let isTarget = dropTargetID == section.id
        return HStack(spacing: 8) {
            if section.package != nil {
                Image(systemName: isTarget ? "folder.fill" : "folder")
                    .font(.system(size: 15))
                    .foregroundStyle(isTarget ? Theme.accent : Color.secondary)
            }
            Text(section.package ?? "Snippets")
                .font(.system(size: 17, weight: .semibold))
            Text("\(section.snippets.count)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTarget ? Theme.accent.opacity(0.15) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isTarget ? Theme.accent : Color.clear, lineWidth: 1.5)
        }
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            let ids = Self.snippetIDs(fromDragItems: items)
            guard !ids.isEmpty else { return false }
            model.move(ids, toPackage: section.package)
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetID = section.id
            } else if dropTargetID == section.id {
                dropTargetID = nil
            }
        }
        .help(section.package == nil ? "Drop snippets here to take them out of their package"
                                     : "Drop snippets here to move them into this package")
    }

    private func card(for snippet: Snippet) -> some View {
        SnippetCardView(snippet: snippet, isSelected: selection.contains(snippet.id))
            .onTapGesture(count: 2) {
                selection = [snippet.id]
                runSnippet = snippet
            }
            // Simultaneous, so selecting doesn't wait for the double-click interval.
            .simultaneousGesture(TapGesture().onEnded {
                click(snippet.id)
            })
            .draggable(dragPayload(for: snippet.id)) {
                dragPreview(for: snippet)
            }
            .contextMenu {
                cardMenu(for: snippet)
            }
            .help("Double-click to run on hosts")
    }

    @ViewBuilder
    private func cardMenu(for snippet: Snippet) -> some View {
        let targets = actionTargets(for: snippet.id)
        Button("Run on hosts\u{2026}") {
            selection = [snippet.id]
            runSnippet = snippet
        }
        Button("Duplicate") { duplicate(snippet.id) }
        Menu(targets.count == 1 ? "Move to" : "Move \(targets.count) snippets to") {
            Button("No package") { model.move(targets, toPackage: nil) }
            if !model.packages.isEmpty {
                Divider()
                ForEach(model.packages, id: \.self) { package in
                    Button(package) { model.move(targets, toPackage: package) }
                }
            }
            Divider()
            Button("New package\u{2026}") {
                newPackageRequest = NewPackageRequest(snippetIDs: targets)
            }
        }
        Divider()
        Button(targets.count == 1 ? "Remove" : "Remove \(targets.count) snippets", role: .destructive) {
            confirmRemove(targets)
        }
    }

    private func dragPreview(for snippet: Snippet) -> some View {
        let count = actionTargets(for: snippet.id).count
        return HStack(spacing: 8) {
            SymbolBadge(symbol: "curlybraces", background: Theme.snippetBadge)
                .frame(width: 24, height: 24)
            Text(count == 1 ? SnippetCardView.displayName(of: snippet) : "\(count) snippets")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.cardBackground)
        }
    }

    private var multipleSelectionPanel: some View {
        let ids = selectedIDs
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(ids.count) snippets selected")
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    selection = []
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Clear the selection (Esc)")
            }
            .frame(height: 52)
            Text("Drag them onto a package's title, or:")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Menu("Move to package") {
                Button("No package") { model.move(ids, toPackage: nil) }
                if !model.packages.isEmpty {
                    Divider()
                    ForEach(model.packages, id: \.self) { package in
                        Button(package) { model.move(ids, toPackage: package) }
                    }
                }
                Divider()
                Button("New package\u{2026}") {
                    newPackageRequest = NewPackageRequest(snippetIDs: ids)
                }
            }
            Button(role: .destructive) {
                confirmRemove(ids)
            } label: {
                Label("Remove \(ids.count) snippets", systemImage: "trash")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: Theme.detailsPanelWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if vault.all(Snippet.self).isEmpty {
                Text("No snippets yet \u{2014} click New snippet")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text("Save a command or script once, then paste or run it on any host.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Text("No matching snippets")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Drag and drop

    /// The dragged card's ids (the whole selection when the card is part of it), one per line.
    private func dragPayload(for id: UUID) -> String {
        actionTargets(for: id).map(\.uuidString).joined(separator: "\n")
    }

    static func snippetIDs(fromDragItems items: [String]) -> [UUID] {
        var seen: Set<UUID> = []
        return items
            .flatMap { $0.split(whereSeparator: \.isNewline) }
            .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }
    }

    // MARK: Actions

    private func createSnippet() {
        let snippet = model.create(name: "New Snippet", script: "", package: nil)
        selection = [snippet.id]
    }

    private func duplicate(_ id: UUID) {
        if let copy = model.duplicate(id) {
            selection = [copy.id]
        }
    }

    private func newPackageExplanation(for request: NewPackageRequest) -> String {
        switch request.snippetIDs.count {
        case 0: return "A new snippet is created in it."
        case 1: return "The snippet moves into it."
        default: return "The \(request.snippetIDs.count) snippets move into it."
        }
    }

    private func createPackage(_ name: String, for request: NewPackageRequest) {
        if request.snippetIDs.isEmpty {
            let snippet = model.create(name: "New Snippet", script: "", package: name)
            selection = [snippet.id]
        } else {
            model.move(request.snippetIDs, toPackage: name)
        }
    }

    private func confirmRemove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        pendingRemoval = ids
        showRemove = true
    }

    private var removalTitle: String {
        pendingRemoval.count == 1 ? "Remove this snippet?" : "Remove \(pendingRemoval.count) snippets?"
    }

    private var removalMessage: String {
        if pendingRemoval.count == 1, let id = pendingRemoval.first, let snippet = vault.get(Snippet.self, id: id) {
            return "\u{201C}\(SnippetCardView.displayName(of: snippet))\u{201D} will be removed from this vault."
        }
        return "They will be removed from this vault."
    }

    private func remove(_ ids: [UUID]) {
        for id in ids {
            model.delete(id)
        }
        selection.subtract(ids)
        pendingRemoval = []
    }

    /// Saves (or forgets) the targets, then opens a session per host that runs the command once ready.
    private func run(_ snippet: Snippet, on hostIDs: [UUID], text: String, saveTargets: Bool) {
        runSnippet = nil
        if saveTargets {
            model.saveTargets(snippet.id, hostIDs: hostIDs)
        } else if snippet.targetHostIDs != nil {
            model.saveTargets(snippet.id, hostIDs: nil)
        }
        do {
            _ = try sessions.runOnHosts(hostIDs, text: text)
        } catch {
            let title = (error as? ConnectionPlanError)?.alertTitle ?? "Something went wrong"
            let message = error.localizedDescription
            // After the sheet has gone, so the alert can present.
            DispatchQueue.main.async {
                errorTitle = title
                errorMessage = message
                showError = true
            }
        }
    }
}
