import SwiftUI
import AppCore
import SwiftSSHUI

/// First launch: join the sync server the Mac uses (as the Mac's welcome sheet does). Nothing else
/// works before this: hosts, keys and snippets all come from the Mac through sync.
struct JoinView: View {
    @Bindable var form: CompanionJoin
    @FocusState private var focus: Field?

    private enum Field { case address, apiKey, passphrase }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("https://sync.example.com", text: $form.serverAddress)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .apiKey }
                        .accessibilityLabel("Sync server address")
                } header: {
                    Text("Sync server")
                } footer: {
                    Text("The same address your Mac uses (Settings \u{2192} Sync).")
                }

                Section {
                    SecureField("API key", text: $form.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .apiKey)
                        .submitLabel(.next)
                        .onSubmit { focus = .passphrase }
                    SecureField("Vault passphrase", text: $form.passphrase)
                        .textContentType(.password)
                        .focused($focus, equals: .passphrase)
                        .submitLabel(.join)
                        .onSubmit(join)
                } header: {
                    Text("Keys")
                } footer: {
                    Text("Use an API key made for this device on your sync server, and the vault passphrase you chose on your Mac. Both stay in this device\u{2019}s Keychain.")
                }

                if let error = form.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warningForeground)
                    }
                }

                Section {
                    Button(action: join) {
                        HStack {
                            Spacer()
                            if form.isJoining {
                                ProgressView()
                                Text("Joining\u{2026}")
                                    .padding(.leading, 6)
                            } else {
                                Text("Join")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!form.canJoin)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.contentBackground)
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(form.isJoining)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.rotation")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.topBarBackground))
                .accessibilityHidden(true)
            Text("Join your sync server")
                .font(.title2.weight(.semibold))
            Text("SwiftSSH on iPhone and iPad connects to the hosts you set up on your Mac. Join the sync server once to bring them here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func join() {
        guard form.canJoin else { return }
        focus = nil
        Task { await form.join() }
    }
}
