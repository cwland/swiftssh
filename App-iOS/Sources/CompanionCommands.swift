import SwiftUI
import AppCore

/// Hardware keyboard shortcuts (iPad and iPhone with a keyboard; hold ⌘ to see them): ⌘F search
/// hosts, ⌘K quick connect, ⌘W close the session, ⌘1…9 switch to a session, ⌘[ / ⌘] previous and
/// next session. Menu key commands come before the terminal's own key handling, so they work while
/// typing in a session.
struct CompanionCommands: Commands {
    let environment: IOSEnvironment

    var body: some Commands {
        CommandMenu("Hosts") {
            Button("Search Hosts") {
                guard environment.isReady else { return }
                environment.sessions?.selectedTabID = nil
                environment.navigation.requestSearch()
            }
            .keyboardShortcut("f")
            Button("Quick Connect\u{2026}") {
                guard environment.isReady else { return }
                environment.navigation.isQuickConnectShown = true
            }
            .keyboardShortcut("k")
        }
        CommandMenu("Session") {
            Button("Close Session") {
                guard let sessions = environment.sessions, let id = sessions.selectedTabID else { return }
                sessions.close(tabID: id)
            }
            .keyboardShortcut("w")
            Button("Previous Session") {
                environment.sessions?.selectPreviousTab(inWindow: nil)
            }
            .keyboardShortcut("[")
            Button("Next Session") {
                environment.sessions?.selectNextTab(inWindow: nil)
            }
            .keyboardShortcut("]")
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button("Session \(number)") {
                    guard let sessions = environment.sessions else { return }
                    let tabs = sessions.tabs
                    guard number <= tabs.count else { return }
                    sessions.selectedTabID = tabs[number - 1].id
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
    }
}
