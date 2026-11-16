import SwiftUI
import AppCore
import CoreModels

/// The tab's shell history panel (Cmd+Y, or "History…" in the tab's menu): floats over the terminal's
/// right edge like the snippets panel. It reads the server's own history files (bash, zsh, fish) over a
/// separate exec channel each time it opens or Refresh is clicked; nothing is stored or synced.
///
/// Newest first, each command once; the search matches every word. Hovering a row shows Paste and Run;
/// a double-click runs. The row's menu adds Copy and Save as Snippet (creates it and, where the window
/// has the Snippets screen, opens it there to name). The shell writes its history file when it exits
/// (bash) or as you go (zsh/fish, depending on its settings), so the newest commands of this session
/// may not be listed yet.
///
/// The close button and Cmd+Y close the panel, and so does Esc while the keyboard focus is in the panel
/// (its search field or list). While the terminal has the focus, Esc goes to the terminal.
struct HistorySidePanel: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let vault: LocalVault
    /// Opens a snippet in the Snippets screen; nil in windows without Vaults.
    let editSnippet: ((UUID) -> Void)?
    let focusTerminal: () -> Void
    let pasteIntoTerminal: (String) -> Bool
    let isBracketedPasteActive: () -> Bool
    let close: () -> Void

    @State private var model: ShellHistoryViewModel?
    @State private var confirmingUnsafePaste: String?
    @State private var savedCommand: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !isConnected {
                notice("History, Paste and Run work while this tab is connected.")
                Divider()
            }
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            content
        }
        .frame(width: SnippetsSidePanel.width)
        .frame(maxHeight: .infinity)
        .background(Theme.contentBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, x: -2, y: 0)
        .onAppear {
            if model == nil {
                let sessions = sessions
                let tabID = tab.id
                model = ShellHistoryViewModel(load: { @MainActor in
                    try await sessions.runCommand(ShellHistory.command, inTab: tabID)
                })
            }
            searchFocused = true
            reload()
        }
        .onDisappear { focusTerminal() }
        // Opened while connecting or reconnecting: read the history once the tab is connected.
        .onChange(of: isConnected) { _, connected in
            if connected, model?.state != .loaded { reload() }
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
        // Esc with the focus in the panel (search field, list) closes it; Esc in the terminal stays there.
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History panel")
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Text("History")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            circleButton("arrow.clockwise", help: "Read the history again", label: "Refresh history", action: reload)
                .disabled(!isConnected || model?.isLoading == true)
            // No Esc shortcut here: it would take Esc from the terminal (see `onExitCommand`).
            circleButton("xmark", help: "Close (\u{2318}Y or Esc in the search field)", label: "Close history panel",
                         action: close)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func circleButton(_ symbol: String, help: String, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private func notice(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
            Text(text)
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
            TextField("Search history", text: searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                // Esc in the field closes the panel; the field editor can swallow `onExitCommand`.
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
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
        switch model?.state {
        case .idle, nil:
            message(symbol: "bolt.horizontal.circle", title: "Not connected yet.",
                    detail: "The history is read from the server once this tab is connected.")
        case .loading:
            VStack {
                ProgressView().controlSize(.small)
                Text("Reading the server\u{2019}s history\u{2026}")
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            message(symbol: "exclamationmark.triangle", title: "Couldn\u{2019}t read the history.", detail: reason)
        case .loaded:
            let commands = model?.commands ?? []
            if commands.isEmpty {
                let searching = !(model?.searchText.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                message(symbol: "clock.arrow.circlepath",
                        title: searching ? "No commands match." : "No history yet.",
                        detail: searching ? nil
                            : "This server has no bash, zsh or fish history this account can read yet. Most shells save it when you log out.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(commands, id: \.self) { command in
                            row(for: command)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func message(symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for command: String) -> some View {
        HistoryPanelRow(
            command: command,
            canDeliver: isConnected,
            saved: savedCommand == command,
            paste: { deliver(command, run: false) },
            run: { deliver(command, run: true) }
        )
        .contextMenu {
            Button("Paste") { deliver(command, run: false) }
                .disabled(!isConnected)
            Button("Run") { deliver(command, run: true) }
                .disabled(!isConnected)
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            Button(editSnippet == nil ? "Save as Snippet" : "Save as Snippet\u{2026}") { saveAsSnippet(command) }
        }
    }

    // MARK: State and actions

    private var isConnected: Bool {
        if case .connected = tab.state { return true }
        return false
    }

    private var searchText: Binding<String> {
        Binding(get: { model?.searchText ?? "" }, set: { model?.searchText = $0 })
    }

    private func reload() {
        guard let model, isConnected else { return }
        Task { await model.reload() }
    }

    private func deliver(_ command: String, run: Bool) {
        guard isConnected else { return }
        if run {
            _ = sessions.deliver(command, as: .run, toTab: tab.id)
        } else if command.contains(where: \.isNewline), !isBracketedPasteActive() {
            confirmingUnsafePaste = command
            return
        } else {
            pasteNow(command)
        }
        returnFocusToTerminal()
    }

    private func pasteNow(_ text: String) {
        if pasteIntoTerminal(text) { return }
        _ = sessions.deliver(text, as: .paste, toTab: tab.id)
    }

    private var unsafePasteLineCount: Int {
        (confirmingUnsafePaste ?? "").split(whereSeparator: \.isNewline).count
    }

    /// Creates a snippet named after the command's first line; opens it to rename where possible,
    /// otherwise marks the row "Saved".
    private func saveAsSnippet(_ command: String) {
        let firstLine = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        let name = firstLine.count > 40 ? String(firstLine.prefix(40)) + "\u{2026}" : firstLine
        let snippet = SnippetsViewModel(vault: vault).create(name: name, script: command, package: nil)
        if let editSnippet {
            editSnippet(snippet.id)
        } else {
            savedCommand = command
        }
    }

    private func returnFocusToTerminal() {
        searchFocused = false
        let focusTerminal = focusTerminal
        Task { @MainActor in
            await Task.yield()
            focusTerminal()
        }
    }
}

/// A command in the history panel; Paste and Run show while the pointer is over it.
private struct HistoryPanelRow: View {
    let command: String
    let canDeliver: Bool
    let saved: Bool
    let paste: () -> Void
    let run: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if saved {
                Text("Saved")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if isHovering {
                HStack(spacing: 4) {
                    Button("Paste", action: paste)
                        .controlSize(.small)
                        .disabled(!canDeliver)
                        .help("Type it into the terminal without running it")
                    Button("Run", action: run)
                        .controlSize(.small)
                        .disabled(!canDeliver)
                        .help("Type it into the terminal and press Return")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Theme.cardBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            if canDeliver { run() }
        }
        .help(canDeliver ? "Double-click to run" : "Paste and Run work while this tab is connected.")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Paste") { if canDeliver { paste() } }
        .accessibilityAction(named: "Run") { if canDeliver { run() } }
    }
}
