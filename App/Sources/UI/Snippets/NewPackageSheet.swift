import SwiftUI

/// Asks for a snippet group name. Groups exist only through their snippets, so the caller either moves
/// snippets into it or creates a new snippet there (`explanation` says which).
///
/// The UI says "group" (or "snippet group"); the code and the stored field still say `package`.
struct NewPackageSheet: View {
    let explanation: String
    let existingPackages: [String]
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New snippet group")
                .font(.system(size: 15, weight: .semibold))
            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("Group name"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            if existingPackages.contains(trimmed) {
                Text("A group with this name already exists.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }
}
