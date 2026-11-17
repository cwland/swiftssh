import SwiftUI
import UIKit
import AppCore
import CoreModels
import SwiftSSHUI

/// "Show Details": where a host connects and how it signs in, read-only (hosts are edited on the
/// Mac). Never shows a secret.
struct HostDetailsSheet: View {
    let hostID: UUID
    let vault: LocalVault
    @Environment(IOSEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let details = currentDetails {
                    Form {
                        Section {
                            row("Address", details.address, copyable: true)
                            if let backup = details.fallbackAddress {
                                row("Backup address", backup, copyable: true)
                            }
                            row("Port", "\(details.port)")
                            row("Username", details.username ?? "None")
                            if let group = details.groupPath {
                                row("Group", group)
                            }
                        }
                        Section("Signs in with") {
                            Text(details.signIn)
                        }
                        Section {
                            Button {
                                dismiss()
                                Task { await environment.connect(hostID: hostID) }
                            } label: {
                                Label("Connect", systemImage: "play.fill")
                            }
                        } footer: {
                            Text("Hosts are edited on your Mac.")
                        }
                    }
                    .navigationTitle(details.label)
                } else {
                    ContentUnavailableView("Host Removed", systemImage: "server.rack",
                                           description: Text("This host no longer exists."))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var currentDetails: CompanionHostDetails? {
        _ = vault.revision
        return CompanionHostDetails(hostID: hostID, vault: vault)
    }

    private func row(_ label: String, _ value: String, copyable: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .contextMenu {
            if copyable {
                Button("Copy") { UIPasteboard.general.string = value }
            }
        }
    }
}
