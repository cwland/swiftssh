import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// Settings: sync (status, Sync Now, Leave sync), the app lock, the terminal theme and
/// text size on this device, and the version.
struct SettingsScreen: View {
    @Environment(IOSEnvironment.self) private var environment
    @State private var confirmsLeaving = false
    @State private var isLeaving = false
    @State private var leaveError: String?

    /// The chosen theme; one outside the built-in list (an older choice) shows as Automatic.
    private var themeSelection: Binding<String?> {
        let settings = environment.terminalSettings
        return Binding(get: {
            settings.defaultThemeID.flatMap { id in CompanionThemes.choices.contains { $0.id == id } ? id : nil }
        }, set: { settings.defaultThemeID = $0 })
    }

    var body: some View {
        @Bindable var terminal = environment.terminalSettings
        Form {
            if let sync = environment.sync {
                Section {
                    LabeledContent("Status", value: Self.status(of: sync.phase))
                    if let server = sync.serverURL {
                        LabeledContent("Server", value: server.host() ?? server.absoluteString)
                    }
                    if let last = sync.lastSyncedAt {
                        LabeledContent("Last synced") {
                            Text(last, style: .relative)
                        }
                    }
                    Button("Sync Now") {
                        Task { await sync.syncNow() }
                    }
                    .disabled(sync.phase == .syncing || isLeaving)
                    Button("Leave Sync\u{2026}", role: .destructive) {
                        confirmsLeaving = true
                    }
                    .disabled(isLeaving)
                } header: {
                    Text("Sync")
                } footer: {
                    if let leaveError {
                        Text(leaveError)
                            .foregroundStyle(Theme.warningForeground)
                    } else {
                        Text("Hosts, groups, identities and snippets come from your Mac. Leave sync to join again, for example after the vault was replaced on your Mac.")
                    }
                }
            }
            Section {
                Toggle("\(DeviceAuthenticator.biometryName) app lock",
                       isOn: Binding(get: { environment.appLock.isEnabled },
                                     set: { environment.appLock.isEnabled = $0 }))
            } footer: {
                Text("Locks SwiftSSH when it opens and when you come back after more than \(Int(AppLock.gracePeriod)) seconds.")
            }
            Section {
                Picker("Theme", selection: themeSelection) {
                    Text("Automatic").tag(String?.none)
                    ForEach(CompanionThemes.choices) { theme in
                        Text(theme.name).tag(Optional(theme.id))
                    }
                }
                .pickerStyle(.navigationLink)
                Stepper(value: $terminal.fontSize, in: TerminalSettings.fontSizeRange) {
                    LabeledContent("Text size", value: "\(terminal.fontSize) pt")
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Used for every session on this device. Automatic follows Light or Dark mode. Pinch a terminal to change the text size.")
            }
            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.contentBackground)
        .navigationTitle("Settings")
        .confirmationDialog("Leave sync?", isPresented: $confirmsLeaving, titleVisibility: .visible) {
            Button("Leave Sync", role: .destructive) {
                Task { await leave() }
            }
        } message: {
            Text("This closes your sessions and removes the hosts, snippets, known hosts and imported keys from this device. Your Mac and the sync server keep everything; join again to get it back.")
        }
    }

    private func leave() async {
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await environment.leaveSync()
            leaveError = nil
        } catch {
            leaveError = "Couldn\u{2019}t finish leaving sync: \(error.localizedDescription)"
        }
    }

    /// "1.0.0 (42)".
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Plain-language sync status.
    static func status(of phase: SyncCoordinator.Phase) -> String {
        switch phase {
        case .notConfigured: "Not set up"
        case .needsVault(_), .locked: "Needs the vault passphrase"
        case .idle: "Up to date"
        case .syncing: "Syncing\u{2026}"
        case .offline(let reason): "Offline: \(reason)"
        case .failed(let reason): reason
        }
    }
}
