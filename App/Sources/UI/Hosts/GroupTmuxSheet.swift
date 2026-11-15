import SwiftUI
import AppCore
import CoreModels

/// The group's "tmux…" sheet: Default (its parents' choice), On with a session name, or Off, for the
/// group's hosts that inherit. Saved with "Save" through `HostsViewModel.setTmux`; an invalid name
/// keeps the sheet open with the error.
struct GroupTmuxSheet: View {
    let model: HostsViewModel
    let group: HostGroup
    let onDone: () -> Void

    @State private var mode: TmuxMode = .inherit
    @State private var name = TmuxChoice.defaultSessionName
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Attach to tmux for group \u{201C}\(group.name.isEmpty ? "Untitled group" : group.name)\u{201D}")
                .font(.system(size: 15, weight: .semibold))
            Text("Hosts in this group that use Default run tmux new -A -s <name> after login, so Reconnect returns to the same session.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Attach to tmux", selection: $mode) {
                Text(model.inheritedTmuxSummary(ofGroup: group.id)).tag(TmuxMode.inherit)
                Text("On").tag(TmuxMode.on)
                Text("Off").tag(TmuxMode.off)
            }
            .labelsHidden()
            if mode == .on {
                TextField("Session name", text: $name, prompt: Text(TmuxChoice.defaultSessionName))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .onChange(of: name) { _, _ in error = nil }
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            switch model.tmuxChoice(ofGroup: group.id) {
            case .inherit: mode = .inherit
            case .off: mode = .off
            case .session(let stored):
                mode = .on
                name = stored
            }
        }
    }

    private func save() {
        let choice: TmuxChoice = switch mode {
        case .inherit: .inherit
        case .off: .off
        case .on: .session(name)
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.setTmux(choice, forGroup: group.id)
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
