import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// Settings: sync status and Sync Now, the app lock.
struct SettingsScreen: View {
    @Environment(IOSEnvironment.self) private var environment

    var body: some View {
        Form {
            if let sync = environment.sync {
                Section("Sync") {
                    LabeledContent("Status", value: Self.status(of: sync.phase))
                    if let last = sync.lastSyncedAt {
                        LabeledContent("Last synced") {
                            Text(last, style: .relative)
                        }
                    }
                    Button("Sync Now") {
                        Task { await sync.syncNow() }
                    }
                    .disabled(sync.phase == .syncing)
                }
            }
            Section {
                Toggle("\(DeviceAuthenticator.biometryName) app lock",
                       isOn: Binding(get: { environment.appLock.isEnabled },
                                     set: { environment.appLock.isEnabled = $0 }))
            } footer: {
                Text("Locks SwiftSSH when it opens and when you come back after more than \(Int(AppLock.gracePeriod)) seconds.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.contentBackground)
        .navigationTitle("Settings")
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
