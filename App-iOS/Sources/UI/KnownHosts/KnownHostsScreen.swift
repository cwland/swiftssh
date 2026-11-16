import SwiftUI
import UIKit
import AppCore
import SwiftSSHUI

/// The server keys this device and your Macs trust, one section per server: search, Copy
/// Fingerprint. No removing here: that would rewrite what your Macs trust (do it on the Mac).
struct KnownHostsScreen: View {
    let vault: LocalVault
    @State private var model: KnownHostsViewModel?

    var body: some View {
        Group {
            if let model {
                KnownHostsList(model: model)
            }
        }
        .navigationTitle("Known Hosts")
        .onAppear { if model == nil { model = KnownHostsViewModel(vault: vault) } }
    }
}

private struct KnownHostsList: View {
    @Bindable var model: KnownHostsViewModel

    var body: some View {
        List {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.keyType)
                                .font(.subheadline.weight(.medium))
                            Text(row.fingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("First seen \(row.firstSeenText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            copyButton(row.fingerprint)
                        }
                        .swipeActions(edge: .trailing) {
                            copyButton(row.fingerprint)
                                .tint(Theme.accent)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.address)
                        if !section.usedBy.isEmpty {
                            Text("Used by " + section.usedBy.map(\.label).joined(separator: ", "))
                                .font(.caption2)
                                .textCase(nil)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.sections.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("No Known Hosts", systemImage: "checkmark.shield",
                                           description: Text("A server\u{2019}s key is added the first time you trust it."))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "Search known hosts")
    }

    private func copyButton(_ fingerprint: String) -> some View {
        Button {
            UIPasteboard.general.string = fingerprint
        } label: {
            Label("Copy Fingerprint", systemImage: "doc.on.doc")
        }
    }
}
