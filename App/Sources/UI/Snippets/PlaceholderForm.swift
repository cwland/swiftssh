import SwiftUI
import AppCore

/// Asks for each `{{name}}` / `{{name:default}}` of a snippet before it is pasted or run: one field per
/// distinct placeholder (prefilled with its default, the first one focused), a live preview of the final
/// command, Return = the action, Esc = cancel. Shown as a sheet by the Snippets screen and the terminal
/// side panel. Values are inserted as typed (no quoting).
struct PlaceholderForm: View {
    let template: SnippetTemplate
    /// "Run", "Paste", "Run on 3 hosts"….
    let actionTitle: String
    /// The filled command.
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String]
    /// Return can reach both the field's onSubmit and the default button: submit only once.
    @State private var didSubmit = false
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Fill in the snippet")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(template.placeholders) { placeholder in
                    GridRow {
                        Text(placeholder.name)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        TextField(placeholder.defaultValue ?? placeholder.name, text: binding(for: placeholder.name))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .focused($focusedName, equals: placeholder.name)
                            .onSubmit(submit)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(preview.isEmpty ? " " : preview)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.searchFieldBackground)
                    }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focusedName = template.placeholders.first?.name }
    }

    /// The final command as it will be pasted or run.
    private var preview: String {
        template.filled(with: values)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func submit() {
        guard !didSubmit else { return }
        didSubmit = true
        onSubmit(preview)
    }
}
