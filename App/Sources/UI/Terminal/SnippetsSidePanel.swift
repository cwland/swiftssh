import SwiftUI
import AppCore
import CoreModels

/// The tab's snippets panel (Cmd+., or "Snippets…" in the tab's menu): floats over the terminal's right
/// edge like the theme panel (the terminal is not resized). A search field (name and script), then the
/// snippets by package. Hovering a row shows Paste (types it without running) and Run (types it and
/// presses Return); a double-click runs. The row's menu adds Run in All Tabs… (every connected tab of
/// this window, after a confirmation naming how many), Edit (opens it in the Snippets screen) and
/// Remove…. A snippet with `{{placeholders}}` asks for their values first (`PlaceholderForm`).
///
/// Nothing is typed into a tab that isn't connected: Paste and Run are disabled with the reason. After
/// Paste or Run the terminal gets the keyboard focus back; the panel stays open. The close button and
/// Esc close the panel (while it is open, Esc does not reach the terminal).
struct SnippetsSidePanel: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let vault: LocalVault
    /// Opens a snippet in the Snippets screen; nil hides Edit and New Snippet (windows without Vaults).
    let editSnippet: ((UUID) -> Void)?
    /// Gives the terminal the keyboard focus again.
    let focusTerminal: () -> Void
    /// Pastes into this tab's terminal like ⌘V (bracketed paste when the shell asked for it).
    let pasteIntoTerminal: (String) -> Bool
    /// Whether the shell turned on bracketed paste (a multi-line paste is then inserted, not run).
    let isBracketedPasteActive: () -> Bool
    let close: () -> Void

    static let width: CGFloat = 300

    /// Built on appear (not in `init`, which runs on every parent body evaluation); the search is the
    /// panel's own and starts empty each time the panel opens.
    @State private var model: SnippetsViewModel?
    @State private var pending: PendingDelivery?
    /// Set when the placeholder form delivered: its dismissal hands the focus back to the terminal.
    @State private var focusAfterSheet = false
    @State private var confirmingRunInAllTabs: Snippet?
    @State private var confirmingRemove: Snippet?
    /// A multi-line Paste waiting for confirmation: without bracketed paste each line would run.
    @State private var confirmingUnsafePaste: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Read for Observation: a snippet edited in the Snippets screen or synced from another Mac
        // redraws the list.
        _ = vault.revision
        return VStack(spacing: 0) {
            header
            Divider()
            if !isConnected {
                notConnectedNotice
                Divider()
            }
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            content
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.contentBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, x: -2, y: 0)
        .onAppear {
            if model == nil { model = SnippetsViewModel(vault: vault) }
            searchFocused = true
        }
        // The search field had the focus: without this, closing the panel leaves the terminal
        // without it.
        .onDisappear {
            focusTerminal()
        }
        .sheet(item: $pending, onDismiss: {
            if focusAfterSheet {
                focusAfterSheet = false
                returnFocusToTerminal()
            }
        }) { pending in
            PlaceholderForm(template: pending.template, actionTitle: pending.actionTitle) { text in
                deliverFilled(text, for: pending)
            } onCancel: {
                self.pending = nil
            }
        }
        .alert(runInAllTabsTitle, isPresented: isPresented($confirmingRunInAllTabs),
               presenting: confirmingRunInAllTabs) { snippet in
            Button("Run") { runInAllTabsConfirmed(snippet) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is typed into every connected tab of this window and Return is pressed.")
        }
        .alert("Paste \(unsafePasteLineCount) lines?",
               isPresented: Binding(get: { confirmingUnsafePaste != nil },
                                    set: { if !$0 { confirmingUnsafePaste = nil } }),
               presenting: confirmingUnsafePaste) { text in
            Button("Paste and Run Each Line") {
                pasteNow(text)
                returnFocusToTerminal()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This server\u{2019}s shell doesn\u{2019}t support safe multi-line paste, so each line runs as soon as it\u{2019}s pasted.")
        }
        .alert(removeTitle, isPresented: isPresented($confirmingRemove),
               presenting: confirmingRemove) { snippet in
            Button("Remove", role: .destructive) { model?.delete(snippet.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is removed from the Snippets screen and from your other Macs that sync this vault.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Snippets panel")
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Text("Snippets")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            if editSnippet != nil {
                Button(action: newSnippet) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New Snippet: creates one and opens it in the Snippets screen")
                .accessibilityLabel("New Snippet")
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Esc closes the panel while it is open.
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc). While this panel is open, Esc closes it instead of reaching the terminal.")
            .accessibilityLabel("Close snippets panel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var notConnectedNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
            Text(Self.notConnectedReason)
                .font(.system(size: Theme.cardSubtitleFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search snippets", text: searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.searchFieldBackground)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            let sections = model.sections
            if sections.allSatisfy(\.snippets.isEmpty) {
                emptyState(searching: !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            if !section.snippets.isEmpty {
                                if section.package != nil || sections.count > 1 {
                                    Text(section.package ?? "Snippets")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .padding(.horizontal, 8)
                                        .padding(.top, 10)
                                        .padding(.bottom, 2)
                                }
                                ForEach(section.snippets) { snippet in
                                    row(for: snippet)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        } else {
            Spacer()
        }
    }

    private func emptyState(searching: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(searching ? "No snippets match." : "No snippets yet.")
                .font(.system(size: 13, weight: .medium))
            if !searching {
                Text("A snippet is a saved command or script you can paste or run here without retyping it.")
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if editSnippet != nil {
                    Button("New Snippet", action: newSnippet)
                        .padding(.top, 2)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for snippet: Snippet) -> some View {
        SnippetPanelRow(
            snippet: snippet,
            canDeliver: isConnected,
            disabledReason: Self.notConnectedReason,
            paste: { deliver(snippet, as: .paste) },
            run: { deliver(snippet, as: .run) }
        )
        .contextMenu {
            Button("Paste") { deliver(snippet, as: .paste) }
                .disabled(!isConnected)
            Button("Run") { deliver(snippet, as: .run) }
                .disabled(!isConnected)
            Button("Run in All Tabs\u{2026}") { confirmingRunInAllTabs = snippet }
                .disabled(connectableTabCount == 0)
            if let editSnippet {
                Divider()
                Button("Edit") { editSnippet(snippet.id) }
            }
            Divider()
            Button("Remove\u{2026}") { confirmingRemove = snippet }
        }
    }

    // MARK: State

    /// Only a connected tab is typed into.
    private var isConnected: Bool {
        if case .connected = tab.state { return true }
        return false
    }

    static let notConnectedReason = "Paste and Run work while this tab is connected."

    private var connectableTabCount: Int {
        sessions.connectableTabCount(inWindow: tab.windowID)
    }

    private var searchText: Binding<String> {
        Binding(get: { model?.searchText ?? "" }, set: { model?.searchText = $0 })
    }

    private var runInAllTabsTitle: String {
        guard let snippet = confirmingRunInAllTabs else { return "" }
        let count = connectableTabCount
        return "Run \u{201C}\(snippet.panelTitle)\u{201D} in \(count) \(count == 1 ? "tab" : "tabs")?"
    }

    private var removeTitle: String {
        guard let snippet = confirmingRemove else { return "" }
        return "Remove \u{201C}\(snippet.panelTitle)\u{201D}?"
    }

    private func isPresented(_ item: Binding<Snippet?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    // MARK: Actions

    /// Paste or Run in this tab; a snippet with placeholders asks for their values first.
    private func deliver(_ snippet: Snippet, as delivery: SnippetDelivery) {
        guard isConnected else { return }
        let template = SnippetTemplate(snippet.script)
        if template.hasPlaceholders {
            pending = PendingDelivery(template: template, target: .thisTab(delivery))
            return
        }
        send(snippet.script, as: delivery)
        returnFocusToTerminal()
    }

    /// Run types the text and Return through the session; Paste goes through the terminal so a
    /// multi-line snippet is inserted rather than run line by line (falls back to the session).
    private func send(_ text: String, as delivery: SnippetDelivery) {
        guard delivery == .paste else {
            _ = sessions.deliver(text, as: .run, toTab: tab.id)
            return
        }
        // Without bracketed paste the shell would run every line but the last: ask first.
        if text.contains(where: \.isNewline), !isBracketedPasteActive() {
            confirmingUnsafePaste = text
            return
        }
        pasteNow(text)
    }

    private func pasteNow(_ text: String) {
        if pasteIntoTerminal(text) { return }
        _ = sessions.deliver(text, as: .paste, toTab: tab.id)
    }

    private var unsafePasteLineCount: Int {
        (confirmingUnsafePaste ?? "").split(whereSeparator: \.isNewline).count
    }

    /// Confirmed "Run in N tabs": runs it in every connected tab of this window (placeholders first).
    private func runInAllTabsConfirmed(_ snippet: Snippet) {
        let template = SnippetTemplate(snippet.script)
        if template.hasPlaceholders {
            let pending = PendingDelivery(template: template, target: .allTabs(count: connectableTabCount))
            // After the alert has gone: one sheet at a time.
            Task { @MainActor in
                await Task.yield()
                self.pending = pending
            }
            return
        }
        _ = sessions.deliverToAllTabs(snippet.script, as: .run, inWindow: tab.windowID)
        returnFocusToTerminal()
    }

    /// The placeholder form's action: the filled command goes where it was meant to.
    private func deliverFilled(_ text: String, for pending: PendingDelivery) {
        switch pending.target {
        case .thisTab(let delivery):
            // The tab may have dropped while the form was open: then nothing is typed.
            guard isConnected else { break }
            send(text, as: delivery)
        case .allTabs:
            _ = sessions.deliverToAllTabs(text, as: .run, inWindow: tab.windowID)
        }
        focusAfterSheet = true
        self.pending = nil
    }

    private func newSnippet() {
        guard let editSnippet, let model else { return }
        let snippet = model.create(name: "New Snippet", script: "", package: nil)
        editSnippet(snippet.id)
    }

    /// After the current update, so the search field (or a closing sheet) doesn't take the focus back.
    private func returnFocusToTerminal() {
        searchFocused = false
        let focusTerminal = focusTerminal
        Task { @MainActor in
            await Task.yield()
            focusTerminal()
        }
    }
}

/// A Paste/Run (or Run in all tabs) waiting for the placeholder form.
private struct PendingDelivery: Identifiable {
    enum Target {
        case thisTab(SnippetDelivery)
        /// The confirmation named `count` tabs.
        case allTabs(count: Int)
    }

    let id = UUID()
    let template: SnippetTemplate
    let target: Target

    var actionTitle: String {
        switch target {
        case .thisTab(.paste): "Paste"
        case .thisTab(.run): "Run"
        case .allTabs(let count): "Run in \(count) \(count == 1 ? "Tab" : "Tabs")"
        }
    }
}

/// A snippet in the panel: its name and the script's first line. While the pointer is over it, Paste
/// and Run buttons show; a double-click runs it.
private struct SnippetPanelRow: View {
    let snippet: Snippet
    let canDeliver: Bool
    let disabledReason: String
    let paste: () -> Void
    let run: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.panelTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(firstLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if isHovering {
                HStack(spacing: 4) {
                    actionButton("Paste", help: "Type it into the terminal without running it", action: paste)
                    actionButton("Run", help: "Type it into the terminal and press Return", action: run)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Theme.cardBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            if canDeliver { run() }
        }
        .help(canDeliver ? "Double-click to run" : disabledReason)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Paste") { if canDeliver { paste() } }
        .accessibilityAction(named: "Run") { if canDeliver { run() } }
    }

    private func actionButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .controlSize(.small)
            .disabled(!canDeliver)
            .help(canDeliver ? help : disabledReason)
    }

    /// The script's first non-empty line ("Empty script" for none).
    private var firstLine: String {
        let line = snippet.script
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? "Empty script"
    }
}

private extension Snippet {
    /// The name, or "Untitled snippet" while it has none.
    var panelTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled snippet" : trimmed
    }
}
