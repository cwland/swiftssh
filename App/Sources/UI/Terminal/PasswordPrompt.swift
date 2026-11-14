import SwiftUI

/// Sheet asking for a password: secure field, "Save password", Connect / Cancel.
struct PasswordPrompt: View {
    /// e.g. "Password for root@example.com".
    let prompt: String
    let connect: (_ password: String, _ save: Bool) -> Void
    let cancel: () -> Void

    @State private var password = ""
    @State private var save = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            Toggle("Save password", isOn: $save)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        connect(password, save)
    }
}
