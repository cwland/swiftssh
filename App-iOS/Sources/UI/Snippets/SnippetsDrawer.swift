import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// The snippets drawer of a session: search, then Paste (inserted, not run) or Run (with Return) on
/// each snippet. A snippet with `{{placeholders}}` asks for their values first.
struct SnippetsDrawer: View {
    let tab: TerminalTab
    let vault: LocalVault
    /// Types the finished text into the session.
    let deliver: (String, SnippetDelivery) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: SnippetsViewModel?
    @State private var filling: Filling?

    /// A snippet waiting for its placeholder values.
    private struct Filling: Identifiable {
        let snippet: Snippet
        let delivery: SnippetDelivery
        var id: UUID { snippet.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    list(model)
                }
            }
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { if model == nil { model = SnippetsViewModel(vault: vault) } }
        .sheet(item: $filling) { filling in
            PlaceholderFormSheet(template: SnippetTemplate(filling.snippet.script),
                                 actionTitle: filling.delivery == .run ? "Run" : "Paste") { text in
                self.filling = nil
                send(text, filling.delivery)
            } onCancel: {
                self.filling = nil
            }
        }
    }

    private func list(_ model: SnippetsViewModel) -> some View {
        @Bindable var model = model
        return List {
            if tab.state != .connected {
                Section {
                    Label("Snippets can be typed once the session is connected.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.sections) { section in
                Section(section.package ?? "Snippets") {
                    ForEach(section.snippets) { snippet in
                        HStack(spacing: 12) {
                            SnippetRow(snippet: snippet)
                            Spacer(minLength: 4)
                            Button {
                                choose(snippet, .paste)
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .accessibilityLabel("Paste \(snippet.name)")
                            Button {
                                choose(snippet, .run)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .accessibilityLabel("Run \(snippet.name)")
                        }
                        .buttonStyle(.borderless)
                        .disabled(tab.state != .connected)
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
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search snippets")
    }

    private func choose(_ snippet: Snippet, _ delivery: SnippetDelivery) {
        if SnippetTemplate(snippet.script).hasPlaceholders {
            filling = Filling(snippet: snippet, delivery: delivery)
        } else {
            send(snippet.script, delivery)
        }
    }

    private func send(_ text: String, _ delivery: SnippetDelivery) {
        deliver(text, delivery)
        dismiss()
    }
}

/// Asks for each `{{name}}` / `{{name:default}}` of a snippet before it is pasted or run: a field per
/// placeholder (prefilled with its default) and a preview of the final command. Values are inserted
/// as typed (no quoting).
struct PlaceholderFormSheet: View {
    let template: SnippetTemplate
    /// "Run" or "Paste".
    let actionTitle: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String]
    @FocusState private var focusedName: String?

    init(template: SnippetTemplate, actionTitle: String,
         onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.template = template
        self.actionTitle = actionTitle
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        var initial: [String: String] = [:]
        for placeholder in template.placeholders {
            initial[placeholder.name] = placeholder.defaultValue ?? ""
        }
        _values = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(template.placeholders) { placeholder in
                        LabeledContent(placeholder.name) {
                            TextField(placeholder.defaultValue ?? placeholder.name, text: binding(for: placeholder.name))
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .focused($focusedName, equals: placeholder.name)
                                .onSubmit(submit)
                        }
                    }
                }
                Section("Preview") {
                    Text(preview.isEmpty ? " " : preview)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Fill In the Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: submit)
                }
            }
            .onAppear { focusedName = template.placeholders.first?.name }
        }
    }

    /// The final command as it will be pasted or run.
    private var preview: String {
        template.filled(with: values)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func submit() {
        onSubmit(preview)
    }
}
