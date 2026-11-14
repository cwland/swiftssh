import SwiftUI
import AppCore
import CoreModels

/// The right-hand Host Details panel. Each edit saves at once through `HostDetailsViewModel`.
/// Create one panel per host (`.id(hostID)`): the view model keeps per-host UI state.
struct HostDetailsPanel: View {
    @State private var details: HostDetailsViewModel
    private let onClose: () -> Void

    /// Tags as typed; committed to the view model on Return, on leaving the field and on close.
    @State private var tagsText: String
    @FocusState private var tagsFieldFocused: Bool
    @State private var revealPassword = false
    @State private var showBadgePicker = false
    @State private var confirmDelete = false
    @State private var showError = false
    @State private var errorMessage = ""

    init(vault: LocalVault, hostID: UUID, onClose: @escaping () -> Void) {
        let details = HostDetailsViewModel(vault: vault, hostID: hostID)
        _details = State(initialValue: details)
        _tagsText = State(initialValue: details.tags.joined(separator: ", "))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    addressCard
                    generalCard
                    portCard
                    credentialsCard
                    if let hint = details.reuseHint {
                        reuseHintCard(hint)
                    }
                    Button("Show more") {}
                        .buttonStyle(.link)
                        .disabled(true)
                        .help("More settings arrive in a later milestone")
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            connectButton
                .padding(16)
        }
        .frame(width: Theme.detailsPanelWidth)
        .frame(maxHeight: .infinity)
        // The Visual Reference gives the panel the sidebar's color (#F6F7F9).
        .background(Theme.sidebarBackground)
        .onDisappear {
            commitTags()
        }
        .confirmationDialog("Delete this host?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete host", role: .destructive) { deleteHost() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(details.label)\u{201D} will be removed from this vault.")
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Text("Host Details")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Menu {
                Button("Delete host", role: .destructive) {
                    confirmDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")

            Button {
                onClose()
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var connectButton: some View {
        Button {
        } label: {
            Text("Connect")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .opacity(0.6)
        .help("SSH sessions arrive in milestone 3")
    }

    // MARK: Cards

    private var addressCard: some View {
        DetailsCard {
            HStack(alignment: .bottom, spacing: 12) {
                Button {
                    showBadgePicker = true
                } label: {
                    BadgeView(badge: details.osBadge, size: 44)
                }
                .buttonStyle(.plain)
                .help("Choose an OS badge")
                .popover(isPresented: $showBadgePicker, arrowEdge: .bottom) {
                    BadgePickerList(selected: details.osBadge) { badge in
                        details.osBadge = badge
                        showBadgePicker = false
                    }
                }

                FieldColumn(title: "Address") {
                    TextField("Address", text: $details.address, prompt: Text("IP or hostname"))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var generalCard: some View {
        DetailsCard {
            FieldColumn(title: "Label") {
                TextField("Label", text: $details.label, prompt: Text("Name shown on the card"))
                    .textFieldStyle(.roundedBorder)
            }
            FieldColumn(title: "Parent group") {
                Picker("Parent group", selection: $details.groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(details.availableGroups) { group in
                        Text(group.name).tag(UUID?.some(group.id))
                    }
                }
                .labelsHidden()
            }
            FieldColumn(title: "Tags") {
                TextField("Tags", text: $tagsText, prompt: Text("Comma-separated, e.g. prod, web"))
                    .textFieldStyle(.roundedBorder)
                    .focused($tagsFieldFocused)
                    .onSubmit {
                        commitTags()
                    }
                    .onChange(of: tagsFieldFocused) { _, isFocused in
                        if !isFocused {
                            commitTags()
                        }
                    }
            }
        }
    }

    private var portCard: some View {
        DetailsCard {
            FieldColumn(title: "SSH port") {
                TextField("SSH port", text: $details.portText, prompt: Text(String(details.effectivePort)))
                    .textFieldStyle(.roundedBorder)
                if let error = details.portError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                } else if let hint = details.inheritedPortHint {
                    Text("Uses \(hint)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var credentialsCard: some View {
        DetailsCard {
            Text("Credentials")
                .font(.system(size: 13, weight: .semibold))
            Picker("Credentials", selection: $details.credentialMode) {
                Text("Identity").tag(CredentialMode.identity)
                Text("Direct").tag(CredentialMode.direct)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch details.credentialMode {
            case .identity:
                identityFields
            case .direct:
                directFields
            }
        }
    }

    @ViewBuilder
    private var identityFields: some View {
        FieldColumn(title: "Identity") {
            Picker("Identity", selection: $details.identityID) {
                Text("None").tag(UUID?.none)
                ForEach(details.availableIdentities) { identity in
                    Text(identity.label.isEmpty ? identity.username : identity.label)
                        .tag(UUID?.some(identity.id))
                }
            }
            .labelsHidden()
            if details.availableIdentities.isEmpty {
                Text("No identities yet. Add one in Keychain.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var directFields: some View {
        FieldColumn(title: "Username") {
            TextField("Username", text: $details.username, prompt: Text("e.g. root"))
                .textFieldStyle(.roundedBorder)
        }
        FieldColumn(title: "Password") {
            HStack(spacing: 6) {
                if revealPassword {
                    TextField("Password", text: $details.password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("Password", text: $details.password)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(revealPassword ? "Hide password" : "Show password")
            }
        }
        FieldColumn(title: "Key") {
            Picker("Key", selection: $details.sshKeyID) {
                Text("None").tag(UUID?.none)
                ForEach(details.availableKeys) { key in
                    Text(key.label).tag(UUID?.some(key.id))
                }
            }
            .labelsHidden()
        }
    }

    private func reuseHintCard(_ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.2")
                    .foregroundStyle(Theme.accent)
                Text(hint)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Create an identity") {
                createIdentity()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
        }
    }

    // MARK: Actions

    private func commitTags() {
        let typed = tagsText.split(separator: ",").map(String.init)
        if typed != details.tags {
            details.tags = typed
        }
        tagsText = details.tags.joined(separator: ", ")
    }

    private func deleteHost() {
        Task {
            do {
                try await details.delete()
                onClose()
            } catch {
                present(error)
            }
        }
    }

    private func createIdentity() {
        Task {
            do {
                _ = try await details.createIdentityFromReusedCredentials()
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: any Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

/// A white rounded card holding a column of fields.
private struct DetailsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground)
        }
    }
}

/// A small caption above its field(s).
private struct FieldColumn<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Every `OSBadge`, for the badge button's popover.
private struct BadgePickerList: View {
    let selected: OSBadge?
    let choose: (OSBadge) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(OSBadge.allCases, id: \.self) { badge in
                    Button {
                        choose(badge)
                    } label: {
                        HStack(spacing: 10) {
                            BadgeView(badge: badge, size: 24)
                            Text(badge.displayName)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.primary)
                            Spacer(minLength: 0)
                            if badge == selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 220, height: 380)
    }
}
