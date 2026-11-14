import SwiftUI
import AppCore

/// Top bar over sidebar + content. The top bar extends into the hidden title bar's area.
struct RootView: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(navigation: environment.navigation)
            Group {
                switch environment.state {
                case .loading:
                    ProgressView("Opening vault…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.contentBackground)
                case .ready(let vault):
                    MainArea(navigation: environment.navigation, vault: vault)
                case .failed(let message):
                    VaultErrorView(message: message) {
                        Task { await environment.load() }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct MainArea: View {
    let navigation: AppNavigation
    let vault: LocalVault
    /// Kept here so search, filters and the open group (and the Keychain search) survive
    /// switching sidebar items. Built once, on appear, rather than in `init` (which runs on
    /// every parent body evaluation).
    @State private var hostsModel: HostsViewModel?
    @State private var keychainModel: KeychainViewModel?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(navigation: navigation)
            Divider()
            VStack(spacing: 0) {
                if let error = vault.lastSaveError {
                    SaveErrorBanner(error: error) {
                        Task { await vault.flush() }
                    }
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if hostsModel == nil {
                hostsModel = HostsViewModel(vault: vault)
            }
            if keychainModel == nil {
                keychainModel = KeychainViewModel(vault: vault)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.sidebar {
        case .hosts:
            if let hostsModel {
                HostsView(model: hostsModel, vault: vault)
            } else {
                Theme.contentBackground
            }
        case .keychain:
            if let keychainModel {
                KeychainView(model: keychainModel, vault: vault)
            } else {
                Theme.contentBackground
            }
        case .snippets, .knownHosts, .logs:
            PlaceholderView("Coming in a later milestone")
        }
    }
}

/// Shown over the content while the vault's last write failed; goes away after the next
/// successful write.
private struct SaveErrorBanner: View {
    let error: any Error
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warningForeground)
            Text("Changes couldn't be saved: \(error.localizedDescription)")
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct VaultErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Your vault could not be opened")
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 560)
            Button("Try Again", action: retry)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }
}
