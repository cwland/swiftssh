import SwiftUI
import UIKit
import AppCore
import CoreModels
import SwiftSSHUI

/// Snippets from the Mac, read-only, by group: search, Copy, and Run in an open session.
struct SnippetsScreen: View {
    let vault: LocalVault
    @Environment(IOSEnvironment.self) private var environment
    @State private var model: SnippetsViewModel?

    var body: some View {
        Group {
            if let model {
                SnippetList(model: model, rowActions: rowActions)
            }
        }
        .navigationTitle("Snippets")
        .onAppear { if model == nil { model = SnippetsViewModel(vault: vault) } }
    }

    @ViewBuilder
    private func rowActions(_ snippet: Snippet) -> some View {
        Button {
            UIPasteboard.general.string = snippet.script
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if let sessions = environment.sessions {
            let connected = sessions.tabs.filter { $0.state == .connected }
            if !connected.isEmpty {
                Menu {
                    ForEach(connected) { tab in
                        Button(tab.displayTitle) {
                            run(snippet, in: tab, sessions: sessions)
                        }
                    }
                } label: {
                    Label("Run in Session", systemImage: "play")
                }
            }
        }
    }

    /// Snippets with placeholders open the session, whose drawer asks for the values.
    private func run(_ snippet: Snippet, in tab: TerminalTab, sessions: SessionManager) {
        sessions.selectedTabID = tab.id
        if SnippetTemplate(snippet.script).hasPlaceholders {
            environment.snippetToFill = SnippetRequest(snippetID: snippet.id, tabID: tab.id)
        } else {
            sessions.deliver(snippet.script, as: .run, toTab: tab.id)
        }
    }
}

/// A snippet to fill in and run in a session (from the Snippets screen).
struct SnippetRequest: Identifiable, Equatable {
    let snippetID: UUID
    let tabID: UUID
    var id: UUID { snippetID }
}

/// The searchable, grouped snippet list shared by the Snippets screen and the drawer.
struct SnippetList<Actions: View>: View {
    @Bindable var model: SnippetsViewModel
    @ViewBuilder let rowActions: (Snippet) -> Actions

    var body: some View {
        List {
            ForEach(model.sections) { section in
                Section(section.package ?? "Snippets") {
                    ForEach(section.snippets) { snippet in
                        SnippetRow(snippet: snippet)
                            .contextMenu { rowActions(snippet) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { rowActions(snippet) }
                    }
                }
            }
        }
        .overlay {
            if model.sections.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("No Snippets", systemImage: "text.alignleft",
                                           description: Text("Add snippets on your Mac; they arrive here through sync."))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "Search snippets")
    }
}

/// Name and the script's first lines.
struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snippet.name.isEmpty ? "Untitled snippet" : snippet.name)
                .font(.body.weight(.medium))
            Text(snippet.script)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
