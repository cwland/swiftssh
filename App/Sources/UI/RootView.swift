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
                    VaultErrorView(message: message)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct MainArea: View {
    let navigation: AppNavigation
    let vault: LocalVault
    /// Kept here so search, filters and the open group survive switching sidebar items. Built
    /// once, on appear, rather than in `init` (which runs on every parent body evaluation).
    @State private var hostsModel: HostsViewModel?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(navigation: navigation)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if hostsModel == nil {
                hostsModel = HostsViewModel(vault: vault)
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
            // Filled in by the Keychain screen.
            Theme.contentBackground
        case .snippets, .knownHosts, .logs:
            PlaceholderView("Coming in a later milestone")
        }
    }
}

private struct VaultErrorView: View {
    let message: String

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
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }
}
