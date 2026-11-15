import SwiftUI

/// Asks for a package name. Packages exist only through their snippets, so the caller either moves
/// snippets into it or creates a new snippet there (`explanation` says which).
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
            Text("New package")
                .font(.system(size: 15, weight: .semibold))
            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("Package name"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            if existingPackages.contains(trimmed) {
                Text("A package with this name already exists.")
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
