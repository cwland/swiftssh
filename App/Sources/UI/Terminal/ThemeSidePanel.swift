import SwiftUI
import AppCore
import CoreModels

/// The tab's "Change Theme…" panel: floats over the terminal's right edge (the terminal is not resized,
/// so nothing reflows) and lists the theme gallery in one column, Default first. A click applies at once
/// and the panel stays open, so themes can be compared on the live terminal. For a saved host the choice
/// is saved to the host (all its tabs follow, and it syncs); a quick connect tab, and a workspace's
/// pane, change only themselves (the workspace saves a pane's theme).
/// The close button and Esc close the panel (while it is open, Esc does not reach the terminal). A host
/// choice is saved shortly after the last click (`SessionManager.applyTheme`), and at once when the panel
/// closes.
struct ThemeSidePanel: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let vault: LocalVault
    let terminalSettings: TerminalSettings
    let close: () -> Void

    static let width: CGFloat = 300

    var body: some View {
        // Read for Observation: a theme saved here, in Host Details or from another Mac redraws the
        // selection ring and the Default card.
        _ = vault.revision
        return VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                ThemeGallery(catalog: .shared,
                             // A pane without its own theme shows Default (it follows its host).
                             selectedThemeID: isPane ? tab.themeOverrideID : sessions.themeChoice(tabID: tab.id),
                             inheritedTheme: inheritedTheme,
                             showsDefault: true,
                             columns: 1) { themeID in
                    sessions.applyTheme(themeID, tabID: tab.id)
                }
                .padding(12)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.contentBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, x: -2, y: 0)
        .onDisappear {
            sessions.flushPendingThemeSaves()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Theme")
                    .font(.system(size: 15, weight: .semibold))
                Text(scopeText)
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Esc closes the panel while it is open.
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc). While this panel is open, Esc closes it instead of reaching the terminal.")
            .accessibilityLabel("Close theme panel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var savedHost: SavedHost? {
        tab.savedHostID.flatMap { vault.get(SavedHost.self, id: $0) }
    }

    /// Says where the choice goes.
    /// The tab is a workspace's pane: its theme is its own (the workspace saves it).
    private var isPane: Bool { sessions.workspace(containing: tab.id) != nil }

    private var scopeText: String {
        if isPane {
            return "This terminal only \u{2014} its host keeps its theme. Save the workspace (\u{2318}S) to keep it."
        }
        if let host = savedHost {
            let name = host.label.isEmpty ? host.address : host.label
            return "Saved to \u{201C}\(name)\u{201D} \u{2014} all its tabs follow."
        }
        return "This tab only."
    }

    /// What Default resolves to: for a saved host its groups' theme, else the app default; nil =
    /// Automatic (the gallery draws SwiftSSH Light/Dark).
    private var inheritedTheme: TerminalTheme? {
        let catalog = TerminalThemeCatalog.shared
        // A pane's Default is its host's own choice.
        if isPane, let id = savedHost?.themeID, let theme = catalog.theme(id: id) {
            return theme
        }
        if let host = savedHost,
           let id = TerminalThemeResolver.inheritedThemeID(forHostID: host.id, hosts: [host],
                                                           groups: vault.all(HostGroup.self)),
           let theme = catalog.theme(id: id) {
            return theme
        }
        return terminalSettings.defaultThemeID.flatMap { catalog.theme(id: $0) }
    }
}
