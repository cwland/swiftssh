import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// The right-hand Host Details panel. Each edit saves at once through `HostDetailsViewModel`.
/// Create one panel per host (`.id(hostID)`): the view model keeps per-host UI state. The view
/// model is built once, on appear, not in `init`, so re-evaluating a parent body is cheap.
struct HostDetailsPanel: View {
    let vault: LocalVault
    let terminalSettings: TerminalSettings
    let hostID: UUID
    let onClose: () -> Void
    let onConnect: () -> Void

    @State private var details: HostDetailsViewModel?

    var body: some View {
        ZStack {
            if let details {
                HostDetailsContent(details: details, vault: vault, terminalSettings: terminalSettings, onClose: onClose, onConnect: onConnect)
            } else {
                Theme.sidebarBackground
                    .frame(width: Theme.detailsPanelWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            if details == nil {
                details = HostDetailsViewModel(vault: vault, hostID: hostID)
            }
        }
    }
}

private struct HostDetailsContent: View {
    @Bindable var details: HostDetailsViewModel
    let vault: LocalVault
    let terminalSettings: TerminalSettings
    let onClose: () -> Void
    let onConnect: () -> Void

    /// Tags as typed. Every change is saved at once; the text is normalized on Return and blur.
    @State private var tagsText = ""
    @FocusState private var tagsFieldFocused: Bool
    @State private var showBadgePicker = false
    @State private var showOSPicker = false
    @State private var showThemeGallery = false
    @State private var confirmDelete = false
    @State private var showError = false
    @State private var errorMessage = ""
    /// A credential change waiting for "Remove" / "Keep" (it makes saved secrets unneeded).
    @State private var pendingChange: PendingCredentialChange?

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
        .onAppear {
            tagsText = details.tags.joined(separator: ", ")
        }
        .confirmationDialog("Delete this host?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete host", role: .destructive) { deleteHost() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(details.label)\u{201D} will be removed from this vault. You can restore it from Settings \u{2192} Recently Deleted.")
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .credentialChangeConfirmation($pendingChange) { change, removingReplaced in
            details.apply(change, removingReplaced: removingReplaced)
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
            .menuStyle(.button)
            .buttonStyle(.borderless)
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
            onConnect()
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
        .help("Open a terminal session to this host")
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
                .help("Choose the OS")
                .popover(isPresented: $showBadgePicker, arrowEdge: .bottom) {
                    osPicker { showBadgePicker = false }
                }

                FieldColumn(title: "Address") {
                    TextField("Address", text: $details.address, prompt: Text("IP or hostname"))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    /// "Automatic (Ubuntu)", "Automatic" before the first detection, or the chosen OS.
    private var osSummary: String {
        guard details.isOSAutomatic else { return BadgeStyle.displayName(for: details.osBadge) }
        guard let badge = details.osBadge else { return "Automatic" }
        return "Automatic (\(BadgeStyle.displayName(for: badge)))"
    }

    private func osPicker(dismiss: @escaping () -> Void) -> some View {
        OSPickerList(selected: details.osBadge, isAutomatic: details.isOSAutomatic,
                     chooseAutomatic: {
                         details.useAutomaticOS()
                         dismiss()
                     },
                     choose: { badge in
                         details.osBadge = badge
                         dismiss()
                     })
    }

    private var generalCard: some View {
        DetailsCard {
            FieldColumn(title: "Label") {
                TextField("Label", text: $details.label, prompt: Text("Name shown on the card"))
                    .textFieldStyle(.roundedBorder)
            }
            themeField
            tmuxField
            startupSnippetField
            FieldColumn(title: "Parent group") {
                Picker("Parent group", selection: $details.groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(details.availableGroups) { group in
                        Text(group.name).tag(UUID?.some(group.id))
                    }
                }
                .labelsHidden()
            }
            FieldColumn(title: "OS") {
                Button {
                    showOSPicker = true
                } label: {
                    HStack(spacing: 8) {
                        BadgeView(badge: details.osBadge, size: 20)
                        Text(osSummary)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Automatic detects the OS when you connect; choosing one keeps it")
                .popover(isPresented: $showOSPicker, arrowEdge: .bottom) {
                    osPicker { showOSPicker = false }
                }
            }
            FieldColumn(title: "Tags") {
                TextField("Tags", text: $tagsText, prompt: Text("Comma-separated, e.g. prod, web"))
                    .textFieldStyle(.roundedBorder)
                    .focused($tagsFieldFocused)
                    .onChange(of: tagsText) { _, text in
                        details.tags = text.split(separator: ",").map(String.init)
                    }
                    .onSubmit {
                        normalizeTagsText()
                    }
                    .onChange(of: tagsFieldFocused) { _, isFocused in
                        if !isFocused {
                            normalizeTagsText()
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

    /// The host's terminal theme, near the top so it is easy to find: a swatch and the current
    /// choice; clicking opens the gallery popover. Each click there saves at once (all the host's
    /// tabs follow) and the popover stays open for comparing.
    private var themeField: some View {
        FieldColumn(title: "Theme") {
            ThemeRowButton(title: details.themeSummary(appDefaultThemeID: terminalSettings.defaultThemeID),
                           swatchTheme: rowSwatchTheme) {
                showThemeGallery = true
            }
            .popover(isPresented: $showThemeGallery, arrowEdge: .leading) {
                ThemeGalleryPopover(title: themeGalleryTitle,
                                    selectedThemeID: details.themeID,
                                    inheritedTheme: details.defaultTheme(appDefaultThemeID: terminalSettings.defaultThemeID),
                                    unknownThemeID: details.unknownThemeID) { id in
                    details.themeID = id
                }
            }
        }
    }

    /// "Attach to tmux": Default (the groups' choice, e.g. "Default (group: on, ops)"), On with a
    /// session name ("main" when first switched on), or Off. Each change saves at once; an invalid
    /// name is shown with its error and not saved.
    private var tmuxField: some View {
        FieldColumn(title: "Attach to tmux") {
            Picker("Attach to tmux", selection: $details.tmuxMode) {
                Text(details.inheritedTmuxSummary).tag(TmuxMode.inherit)
                Text("On").tag(TmuxMode.on)
                Text("Off").tag(TmuxMode.off)
            }
            .labelsHidden()
            .help("After login, run tmux new -A -s <name>, so Reconnect returns to the same session")
            if details.tmuxMode == .on {
                TextField("Session name", text: $details.tmuxNameText,
                          prompt: Text(TmuxChoice.defaultSessionName))
                    .textFieldStyle(.roundedBorder)
                if let error = details.tmuxNameError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                } else {
                    Text("Skipped with a message when tmux isn\u{2019}t installed on the server.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Startup snippet": runs after sign-in, before tmux attach. Default uses the nearest group's
    /// ("Default (from group “Ops”: …)"); None runs nothing, not even a group's. Only snippets without
    /// `{{placeholders}}` can be chosen. A saved choice that now has placeholders stays visible as
    /// "(unavailable)" so the user can see it and pick another.
    private var startupSnippetField: some View {
        let candidates = details.startupCandidates()
        let selection = details.startupSnippetSelection
        let unavailableID: UUID? = {
            guard case .snippet(let id) = selection, !candidates.contains(where: { $0.id == id }) else { return nil }
            return id
        }()
        let hasHidden = details.hiddenStartupSnippetCount > 0
        return FieldColumn(title: "Startup snippet") {
            Picker("Startup snippet", selection: $details.startupSnippetSelection) {
                Text(details.inheritedStartupSnippetSummary).tag(StartupSnippetSelection.inherit)
                Text("None").tag(StartupSnippetSelection.none)
                if let unavailableID {
                    Text("(unavailable)").tag(StartupSnippetSelection.snippet(unavailableID))
                }
                ForEach(candidates) { snippet in
                    Text(startupSnippetPickerTitle(snippet)).tag(StartupSnippetSelection.snippet(snippet.id))
                }
            }
            .labelsHidden()
            .help("A snippet typed into the terminal each time this host connects")
            Text("Runs after you sign in, before tmux attach.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if hasHidden {
                Text("Snippets with {{placeholders}} can\u{2019}t run at startup.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The host's own theme when this build knows it, else what Default resolves to (which is
    /// also what its tabs draw with for an unknown id); nil = Automatic.
    private var rowSwatchTheme: TerminalTheme? {
        if let id = details.themeID, let theme = TerminalThemeCatalog.shared.theme(id: id) { return theme }
        return details.defaultTheme(appDefaultThemeID: terminalSettings.defaultThemeID)
    }

    private var themeGalleryTitle: String {
        let name = details.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? details.address : name
        return shown.isEmpty ? "Theme" : "Theme for \u{201C}\(shown)\u{201D}"
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
        if let resolved = effectiveCredentials, resolved.agentKey != nil {
            KeyInstallCommandButton(port: details.effectivePort, username: resolved.username,
                                    address: details.address)
        }
    }

    /// What the app will actually log in with for this host (explicit identity, or the group default),
    /// through the same `CredentialResolution` the connection uses.
    private var effectiveCredentials: CredentialResolution? {
        _ = vault.revision
        guard let host = vault.get(SavedHost.self, id: details.hostID) else { return nil }
        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        return CredentialResolution.resolve(host: host, directory: directory, vault: vault)
    }

    @ViewBuilder
    private var directFields: some View {
        FieldColumn(title: "Username") {
            TextField("Username", text: $details.username, prompt: Text("e.g. root"))
                .textFieldStyle(.roundedBorder)
        }
        LoginMethodPicker(method: loginMethod)
        switch loginMethod.wrappedValue {
        case .onePasswordAgent:
            OnePasswordAgentKeyPicker(choice: $details.agentKey)
            KeyInstallCommandButton(port: details.effectivePort, username: details.username,
                                    address: details.address)
        case .passwordOrKey:
            FieldColumn(title: "Password") {
                OnePasswordPasswordField(title: "Password", text: $details.password) { reference in
                    request(.passwordReference(reference))
                }
            }
            FieldColumn(title: "Key") {
                Picker("Key", selection: keySelection) {
                    Text("None").tag(UUID?.none)
                    ForEach(details.availableKeys) { key in
                        Text(key.label).tag(UUID?.some(key.id))
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: 1Password agent

    /// Switching to Identity, or linking one, clears `agentKey` (in `HostDetailsViewModel`). Switching
    /// to the agent asks whether to remove the saved password and key link (`request`).
    private var loginMethod: Binding<LoginMethod> {
        Binding(get: { LoginMethod(agentKey: details.agentKey) },
                set: { method in
                    switch method {
                    case .passwordOrKey:
                        details.agentKey = nil
                    case .onePasswordAgent:
                        if details.agentKey == nil { request(.agent(AgentKeyChoice(publicKey: nil))) }
                    }
                })
    }

    /// Choosing a key asks whether to remove a saved password; "None" just unlinks the key.
    private var keySelection: Binding<UUID?> {
        Binding(get: { details.sshKeyID },
                set: { keyID in
                    guard let keyID else {
                        details.sshKeyID = nil
                        return
                    }
                    if keyID != details.sshKeyID { request(.key(keyID)) }
                })
    }

    /// Applies `change` at once when it replaces nothing; otherwise asks first (Cancel changes nothing).
    private func request(_ change: CredentialChange) {
        let replaced = details.secretsReplaced(by: change)
        if replaced.isEmpty {
            details.apply(change, removingReplaced: false)
        } else {
            let name = details.label.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingChange = PendingCredentialChange(change: change, replaced: replaced,
                                                    name: name.isEmpty ? details.address : name)
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

    /// Shows the saved (trimmed, deduplicated) tags in the field.
    private func normalizeTagsText() {
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

/// A snippet as the startup snippet pickers list it: "Name – Snippet group" when it is in a snippet
/// group, else "Name".
func startupSnippetPickerTitle(_ snippet: Snippet) -> String {
    let name = snippet.name.isEmpty ? "Untitled snippet" : snippet.name
    guard let group = snippet.package, !group.isEmpty else { return name }
    return "\(name) \u{2013} \(group)"
}

/// A white rounded card holding a column of fields.
struct DetailsCard<Content: View>: View {
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
struct FieldColumn<Content: View>: View {
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

/// The OS choice: "Automatic", then the catalog grouped by category, with a search field.
private struct OSPickerList: View {
    let selected: OSBadge?
    let isAutomatic: Bool
    let chooseAutomatic: () -> Void
    let choose: (OSBadge) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Search"))
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    if trimmedQuery.isEmpty {
                        row(title: "Automatic", isSelected: isAutomatic, action: chooseAutomatic) {
                            Image(systemName: "wand.and.stars")
                                .frame(width: 24, height: 24)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(categories) { category in
                        Section {
                            ForEach(category.entries) { entry in
                                row(title: entry.name, isSelected: !isAutomatic && entry.id == selected,
                                    action: { choose(entry.id) }) {
                                    BadgeView(badge: entry.id, size: 24)
                                }
                            }
                        } header: {
                            Text(category.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .background(.background)
                        }
                    }
                    if categories.isEmpty {
                        Text("No match")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 300, height: 440)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct PickerSection: Identifiable {
        let id: String
        let title: String
        let entries: [OSCatalog.Entry]
    }

    /// Categories with only the entries whose name, id or category matches the search.
    private var categories: [PickerSection] {
        let text = trimmedQuery
        return OSCatalog.shared.categories.compactMap { category in
            let matches = text.isEmpty ? category.entries : category.entries.filter {
                $0.name.localizedStandardContains(text) || $0.id.rawValue.localizedStandardContains(text)
                    || category.title.localizedStandardContains(text)
            }
            return matches.isEmpty ? nil : PickerSection(id: category.key, title: category.title, entries: matches)
        }
    }

    private func row<Icon: View>(title: String, isSelected: Bool, action: @escaping () -> Void,
                                 @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
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
