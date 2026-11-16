import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// The joined app. iPad (regular width): a sidebar (Hosts, Snippets, Known Hosts, Keys, Settings, with
/// counts) and the section beside it, with the open sessions as tabs across the top. iPhone (compact
/// width): Hosts in a navigation stack (the other sections pushed from its menu), a session full
/// screen, and a floating pill to switch sessions. A selected session (`SessionManager.selectedTabID`)
/// replaces the sections; nil shows them.
struct RootView: View {
    @Environment(IOSEnvironment.self) private var environment
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var navigation = environment.navigation
        Group {
            if let sessions = environment.sessions, let vault = environment.vault {
                if sizeClass == .regular {
                    PadRootView(sessions: sessions, vault: vault)
                } else {
                    PhoneRootView(sessions: sessions, vault: vault)
                }
            }
        }
        // Let go of the terminal views of sessions that were closed.
        .onChange(of: environment.sessions?.tabs.map(\.id) ?? []) { _, ids in
            environment.terminalViews.retain(only: Set(ids))
        }
        .sheet(isPresented: $navigation.isQuickConnectShown) {
            QuickConnectSheet()
        }
        .alert(environment.connectProblem?.title ?? "", isPresented: problemShown, presenting: environment.connectProblem) { problem in
            if problem.offersImport {
                Button("Import Key") {
                    environment.sessions?.selectedTabID = nil
                    environment.navigation.show(.keys)
                }
            }
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { environment.connectProblem != nil },
                set: { if !$0 { environment.connectProblem = nil } })
    }
}

// MARK: iPad

/// Sidebar and section, the session tabs across the top.
private struct PadRootView: View {
    let sessions: SessionManager
    let vault: LocalVault
    @Environment(IOSEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            if !sessions.tabs.isEmpty {
                SessionTabBar(sessions: sessions)
            }
            if let tab = selectedTab {
                SessionScreen(tab: tab, sessions: sessions, vault: vault)
            } else {
                sections
            }
        }
    }

    private var selectedTab: TerminalTab? {
        sessions.selectedTabID.flatMap { id in sessions.tabs.first { $0.id == id } }
    }

    private var sections: some View {
        let navigation = environment.navigation
        return NavigationSplitView {
            List(selection: Binding<CompanionSection?>(get: { navigation.section },
                                                       set: { if let section = $0 { navigation.show(section) } })) {
                let counts = CompanionSidebarCounts(vault: vault, importedKeyCount: environment.importedKeys.keys.count)
                ForEach(CompanionSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.symbol)
                            .badge(counts.count(for: section) ?? 0)
                    }
                }
            }
            .navigationTitle("SwiftSSH")
        } detail: {
            NavigationStack {
                SectionScreen(section: navigation.section, vault: vault)
            }
            .id(navigation.section)
        }
    }
}

// MARK: iPhone

/// Hosts with the other sections pushed over it; a session full screen; the floating session pill.
private struct PhoneRootView: View {
    let sessions: SessionManager
    let vault: LocalVault
    @Environment(IOSEnvironment.self) private var environment

    var body: some View {
        @Bindable var navigation = environment.navigation
        if let tab = selectedTab {
            SessionScreen(tab: tab, sessions: sessions, vault: vault)
        } else {
            NavigationStack(path: $navigation.phonePath) {
                SectionScreen(section: .hosts, vault: vault)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                ForEach(CompanionSection.allCases.filter { $0 != .hosts }) { section in
                                    Button {
                                        navigation.show(section)
                                    } label: {
                                        Label(section.title, systemImage: section.symbol)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("More")
                        }
                    }
                    .navigationDestination(for: CompanionSection.self) { section in
                        SectionScreen(section: section, vault: vault)
                    }
            }
            .overlay(alignment: .bottom) {
                if !sessions.tabs.isEmpty {
                    SessionPill(sessions: sessions)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private var selectedTab: TerminalTab? {
        sessions.selectedTabID.flatMap { id in sessions.tabs.first { $0.id == id } }
    }
}

// MARK: Sections

/// One section's screen.
struct SectionScreen: View {
    let section: CompanionSection
    let vault: LocalVault
    @Environment(IOSEnvironment.self) private var environment

    var body: some View {
        switch section {
        case .hosts:
            if let hosts = environment.hosts, let sessions = environment.sessions {
                HostsScreen(model: hosts, sessions: sessions, vault: vault)
            }
        case .snippets:
            SnippetsScreen(vault: vault)
        case .knownHosts:
            KnownHostsScreen(vault: vault)
        case .keys:
            KeysScreen(vault: vault)
        case .settings:
            SettingsScreen()
        }
    }
}
