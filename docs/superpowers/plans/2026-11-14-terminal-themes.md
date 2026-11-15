# Milestone 5: Terminal Themes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Follow superpowers:test-driven-development: write the failing test, run it and see it fail, implement, see it pass, commit.

**Goal:** Settings → Terminal (text size stepper + two-column theme gallery as the app-wide default), a bundled catalog of 20 license-checked themes, per-host and per-group theme pickers on the existing synced fields, and live re-theming of open tabs. Ships as **v0.6.0**.

**Spec:** `docs/superpowers/specs/2026-11-14-terminal-themes-design.md`. Open questions are in its §11; where Cory has not answered, build the recommended default described there (Automatic first card, per-Mac default and text size, group context-menu picker, names "Reimagined Light/Dark", 9–24 pt, upstream colors exactly, no extra variants, no zoom shortcuts).

**Tech stack:** Swift 6, macOS 15, SwiftUI/AppKit, SwiftTerm 1.99.3, XcodeGen (`App/project.yml`), `Packages/CoreSSH` (CoreModels / SyncCore / AppCore / SSHCore).

## Global constraints

- Package tests (Linux sandbox): `cd Packages/CoreSSH && swift test -Xlinker --allow-shlib-undefined` (the flag is sandbox-only, never in `Package.swift`). The app target does not build on Linux; app tasks are verified by Cory on the Mac (`cd App && xcodegen && xcodebuild -scheme TermiusReimagined test`).
- Theme ids are stored in synced records (`Host.themeID`, `HostGroup.defaultThemeID`) — never rename an id once shipped.
- No Termius assets, names or colors. Third-party colors come only from the upstream files named in the JSON `credits`.
- Per-Mac settings keys: `terminal.defaultThemeID` (String; absent = Automatic), `terminal.fontSize` (Int; absent = 13). Range 9…24.
- `SettingsPane.allCases == [.connection, .terminal, .sync, .onePassword, .osIcons]`.
- Commit author `Cory <cwland@users.noreply.github.com>`; message prefixes `feat(core):`, `feat(app):`, `test:`, `docs:`, `chore(app):`; end every message with the session trailers.
- Version: `App/project.yml` `MARKETING_VERSION: "0.6.0"` (Task 5 only).

## Work split for parallel subagents

```
Wave 1 (one worktree):   Task 1  core theme model + catalog + resolver + settings     branch m5-core
                                  (also the minimal app adapter so main still builds)
Wave 2 (three worktrees, in parallel, each branched from m5-core):
                         Task 2  Settings → Terminal pane                              branch m5-settings
                         Task 3  Host Details picker + group picker                    branch m5-pickers
                         Task 4  live apply in terminal tabs                           branch m5-live
Wave 3 (merge worktree): Task 5  merge 2–4, version 0.6.0, README, Mac checkpoint      branch m5-themes
```

File ownership (no two Wave-2 tasks touch the same file):

| File | Owner |
|---|---|
| `Packages/CoreSSH/Sources/CoreModels/HostQueries.swift`, `Tests/CoreModelsTests/HostQueriesTests.swift` | 1 |
| `Packages/CoreSSH/Sources/AppCore/Terminal/*` (new), `Resources/terminal-themes.json`, `Resources/terminal-themes-notices.txt`, `Package.swift` resources | 1 |
| `Tests/AppCoreTests/TerminalTheme*Tests.swift`, `TerminalSettingsTests.swift` | 1 |
| `App/Sources/UI/Terminal/TerminalTheme+AppKit.swift` (new), app-local `TerminalTheme` removal in `SwiftTermView.swift`, `AppEnvironment.swift` (`terminalSettings` line) | 1 |
| `AppCore/ViewModels/SettingsPane.swift`, `Tests/AppCoreTests/BadgeImageRulesTests.swift` (`testSettingsPanes`), `App/Sources/UI/Settings/*`, `App/Sources/TermiusReimaginedApp.swift` | 2 |
| `AppCore/ViewModels/HostDetailsViewModel.swift`, `HostsViewModel.swift` + their tests, `App/Sources/UI/Hosts/*` | 3 |
| `AppCore/Sessions/SessionManager.swift` (`savedHostID`) + `SessionManagerTests.swift`, `App/Sources/UI/Terminal/SwiftTermView.swift`, `TerminalTabView.swift`, `App/Sources/UI/RootView.swift` | 4 |
| `App/project.yml`, `README.md` | 5 |

---

## Task 1 — Core theme model, catalog, resolver, settings (Wave 1)

Worktree: `git worktree add ../wt-m5-core -b m5-core m5-themes`.

### Files

```
Packages/CoreSSH/Sources/CoreModels/HostQueries.swift                 + themeIDChain(for:)
Packages/CoreSSH/Sources/AppCore/Terminal/RGBColor.swift              new
Packages/CoreSSH/Sources/AppCore/Terminal/TerminalTheme.swift         new (TerminalTheme, ThemeAppearance, ThemeCredit)
Packages/CoreSSH/Sources/AppCore/Terminal/TerminalThemeCatalog.swift  new
Packages/CoreSSH/Sources/AppCore/Terminal/TerminalThemeResolver.swift new (+ TerminalAppearance)
Packages/CoreSSH/Sources/AppCore/Terminal/TerminalSettings.swift      new
Packages/CoreSSH/Sources/AppCore/Resources/terminal-themes.json       new (content in Appendix A)
Packages/CoreSSH/Sources/AppCore/Resources/terminal-themes-notices.txt new (Appendix B)
Packages/CoreSSH/Package.swift                                        AppCore resources += the two files
Packages/CoreSSH/Tests/CoreModelsTests/HostQueriesTests.swift         + chain tests
Packages/CoreSSH/Tests/AppCoreTests/RGBColorTests.swift               new
Packages/CoreSSH/Tests/AppCoreTests/TerminalThemeCatalogTests.swift   new
Packages/CoreSSH/Tests/AppCoreTests/TerminalThemeResolverTests.swift  new
Packages/CoreSSH/Tests/AppCoreTests/TerminalSettingsTests.swift       new
App/Sources/UI/Terminal/TerminalTheme+AppKit.swift                    new
App/Sources/UI/Terminal/SwiftTermView.swift                           delete app-local struct TerminalTheme; use catalog light/dark
App/Sources/AppEnvironment.swift                                      + let terminalSettings = TerminalSettings()
```

### Signatures

```swift
// CoreModels/HostQueries.swift
extension HostDirectory {
    /// The host's own theme id, then each group's `defaultThemeID` up the parent chain
    /// (nearest first, cycle-safe, deleted groups skipped). nil levels are left out.
    public func themeIDChain(for host: Host) -> [String]
}
// effectiveThemeID(for:) becomes `themeIDChain(for: host).first` (same results as today).

// AppCore/Terminal/RGBColor.swift
public struct RGBColor: Hashable, Sendable {
    public var red: UInt8, green: UInt8, blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8)
    /// "#RRGGBB" or "RRGGBB", any case, surrounding whitespace ignored. Anything else → nil.
    public init?(hex: String)
    /// "#RRGGBB", uppercase.
    public var hex: String { get }
    /// WCAG 2 relative luminance, 0…1.
    public var relativeLuminance: Double { get }
    /// WCAG 2 contrast ratio, 1…21.
    public func contrastRatio(with other: RGBColor) -> Double
}

// AppCore/Terminal/TerminalTheme.swift
public enum ThemeAppearance: String, Sendable, Hashable { case light, dark }

public struct ThemeCredit: Hashable, Sendable {
    public let key: String          // "dracula"
    public let project: String      // "Dracula"
    public let author: String
    public let license: String      // "MIT"
    public let copyright: String
    public let url: String
    public let files: String
}

public struct TerminalTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let appearance: ThemeAppearance
    public let background: RGBColor
    public let foreground: RGBColor
    public let cursor: RGBColor
    public let selection: RGBColor
    /// Exactly 16: normal 0–7 (black, red, green, yellow, blue, magenta, cyan, white), bright 8–15.
    public let ansi: [RGBColor]
    public let credit: ThemeCredit?
}

// AppCore/Terminal/TerminalThemeCatalog.swift
public enum TerminalThemeCatalogError: Error, Equatable, Sendable {
    case notAJSONObject
    case unsupportedVersion(Int)
}

public struct TerminalThemeCatalog: Sendable {
    public static let lightDefaultID = "reimagined-light"
    public static let darkDefaultID = "reimagined-dark"
    /// Loaded from `Bundle.module` `terminal-themes.json`; a load failure is a programmer error
    /// (fatalError with the reason) because the file ships with the app and is tested.
    public static let shared: TerminalThemeCatalog
    /// Throws for a non-object or a `version` other than 1. A theme entry with a missing field,
    /// a bad hex, an ansi count other than 16, an unknown appearance, a duplicate id or an
    /// unknown credit key is skipped (and listed in `skippedEntries`).
    public init(jsonData: Data) throws(TerminalThemeCatalogError)
    /// File order = gallery order.
    public let themes: [TerminalTheme]
    /// Ids (or "#<index>" when the id is unreadable) of entries that were skipped.
    public let skippedEntries: [String]
    public func theme(id: String) -> TerminalTheme?
    public func contains(_ id: String) -> Bool
    /// Credits used by at least one theme, in first-use order.
    public var credits: [ThemeCredit] { get }
    /// Reimagined Light or Reimagined Dark.
    public func automatic(prefersDark: Bool) -> TerminalTheme
    /// The bundled notices text (`terminal-themes-notices.txt`), "" if missing.
    public static var noticesText: String { get }
}

// AppCore/Terminal/TerminalThemeResolver.swift
public struct TerminalAppearance: Equatable, Sendable {
    public var theme: TerminalTheme
    public var fontSize: Int
    public init(theme: TerminalTheme, fontSize: Int)
}

public enum TerminalThemeResolver {
    /// First id in the host's chain that the catalog knows, else `defaultThemeID` if known,
    /// else `catalog.automatic(prefersDark:)`. A nil, missing or deleted host uses the default.
    public static func theme(forHostID hostID: UUID?, hosts: [SavedHost], groups: [HostGroup],
                             defaultThemeID: String?, prefersDark: Bool,
                             catalog: TerminalThemeCatalog = .shared) -> TerminalTheme
    /// The first id in the chain of the host's *group* (the host's own id ignored) that the
    /// catalog knows; nil = the app default. For "Default (…)" labels.
    public static func inheritedThemeID(forHostID hostID: UUID, hosts: [SavedHost], groups: [HostGroup],
                                        catalog: TerminalThemeCatalog = .shared) -> String?
    /// The same for a group: the first known id among its *parents* (its own ignored).
    public static func inheritedThemeID(forGroupID groupID: UUID, groups: [HostGroup],
                                        catalog: TerminalThemeCatalog = .shared) -> String?
}

// AppCore/Terminal/TerminalSettings.swift
/// Settings → Terminal, stored per Mac in UserDefaults (never synced).
@MainActor @Observable
public final class TerminalSettings {
    static let defaultThemeKey = "terminal.defaultThemeID"
    static let fontSizeKey = "terminal.fontSize"
    public static let fontSizeRange = 9...24
    public static let defaultFontSize = 13
    /// nil = Automatic. Setting nil removes the key; an id the catalog doesn't know is ignored
    /// (the value stays as it was).
    public var defaultThemeID: String? { get set }
    /// Clamped to `fontSizeRange` on set and on read.
    public var fontSize: Int { get set }
    public var canIncreaseFontSize: Bool { get }
    public var canDecreaseFontSize: Bool { get }
    public func increaseFontSize()
    public func decreaseFontSize()
    /// A stored id the catalog doesn't know reads as nil (Automatic).
    public init(defaults: UserDefaults = .standard, catalog: TerminalThemeCatalog = .shared)
}
```

### Steps

- [ ] **1.1 Chain (CoreModels).** Tests in `HostQueriesTests`:
  `testThemeIDChainListsHostThenGroupsNearestFirst`, `testThemeIDChainSkipsNilLevels`, `testThemeIDChainSkipsDeletedGroups`, `testThemeIDChainStopsOnCycle`, `testThemeIDChainForHostWithoutGroupIsOwnIDOnly`, `testEffectiveThemeIDIsFirstOfChain` (existing `effectiveThemeID` tests must stay green). Run → fail. Implement with a cycle-safe walk like `firstInChain`. Run → pass. Commit `feat(core): HostDirectory.themeIDChain for theme fallback`.
- [ ] **1.2 RGBColor.** `RGBColorTests`: `testParsesHashAndBareHexAnyCase`, `testRejectsMalformedHex` ("", "#12345", "#1234567", "GGGGGG", "#12 456"), `testHexIsUppercaseWithHash`, `testRelativeLuminanceOfBlackAndWhite` (0, 1), `testContrastRatioBlackWhiteIs21`, `testContrastRatioIsSymmetric`. Implement. Commit `feat(core): RGBColor`.
- [ ] **1.3 Catalog parsing.** Add `terminal-themes.json` (Appendix A, verbatim) and `.copy("Resources/terminal-themes.json")`, `.copy("Resources/terminal-themes-notices.txt")` to AppCore resources. `TerminalThemeCatalogTests`:
  - `testInitRejectsNonObject`, `testInitRejectsUnknownVersion`
  - `testSkipsEntryWithBadHex`, `testSkipsEntryWithFifteenANSIColors`, `testSkipsDuplicateID` (first kept), `testSkipsUnknownCreditKey`, `testSkipsUnknownAppearance`
  - `testKeepsFileOrder`
  - `testSharedCatalogHasTwentyThemesInGalleryOrder` — asserts the exact id list: `reimagined-light, reimagined-dark, flexoki-dark, flexoki-light, kanagawa-wave, kanagawa-dragon, kanagawa-lotus, everforest-dark, everforest-light, night-owl, light-owl, rose-pine, aura, dracula, solarized-dark, solarized-light, nord, hacker-blue, hacker-green, hacker-red`, and `skippedEntries.isEmpty`
  - `testSharedCatalogAppearanceMatchesBackgroundLuminance` (dark < 0.05, light > 0.8)
  - `testSharedCatalogForegroundContrastAtLeastFour`
  - `testEveryThirdPartyThemeHasACreditAndOriginalsHaveNone` (originals: reimagined-*, hacker-*)
  - `testEveryCreditIsMITAndAppearsInNotices` (each `credit.copyright` and `credit.url` is a substring of `noticesText`)
  - `testAutomaticPicksReimaginedLightOrDark`
  - `testSpotCheckUpstreamValues`: dracula bg `#282A36`, ansi[5] `#FF79C6`; nord ansi[14] `#8FBCBB`; solarized-dark ansi[8] `#002B36`, fg `#839496`; night-owl ansi[3] `#C5E478`; flexoki-light bg `#FFFCF0`; kanagawa-wave cursor `#C8C093`; everforest-dark ansi[0] `#475258`.
  Implement with private `Decodable` file structs read field by field (as `BadgeSettings` does). Commit `feat(core): bundled terminal theme catalog (20 themes)`.
- [ ] **1.4 Notices.** Create `terminal-themes-notices.txt` per Appendix B. Test from 1.3 (`testEveryCreditIsMITAndAppearsInNotices`) now passes. Commit `docs: third-party notices for bundled terminal themes`.
- [ ] **1.5 Resolver.** `TerminalThemeResolverTests` (pure; build `SavedHost`/`HostGroup` values directly):
  `testHostOwnThemeWins`, `testInheritsNearestGroupTheme`, `testInheritsGrandparentWhenParentHasNone`, `testUnknownHostThemeFallsToGroup`, `testUnknownEverywhereFallsToAppDefault`, `testUnknownAppDefaultFallsToAutomatic`, `testAutomaticFollowsPrefersDark`, `testNilHostIDUsesAppDefault` (quick connect), `testDeletedHostUsesAppDefault`, `testInheritedThemeIDIgnoresHostsOwn`, `testInheritedThemeIDForGroupIgnoresGroupsOwn`, `testInheritedThemeIDNilWhenNothingKnown`. Implement. Commit `feat(core): TerminalThemeResolver`.
- [ ] **1.6 TerminalSettings.** `TerminalSettingsTests` (UserDefaults suite per test, like `ConnectionSettingsTests`):
  `testDefaultsWhenNothingStored` (nil, 13), `testPersistsDefaultThemeID`, `testSettingNilRemovesKey`, `testIgnoresUnknownThemeIDOnSet`, `testUnknownStoredThemeIDReadsAsAutomatic`, `testFontSizeClampedOnSetAndRead` (stored 99 → 24, 3 → 9), `testIncreaseDecreaseStopAtBounds`, `testCanIncreaseCanDecrease`, `testFontSizePersists`. Implement. Commit `feat(core): TerminalSettings (per-Mac default theme and text size)`.
- [ ] **1.7 App adapter (keeps main building, no behaviour change).** New `App/Sources/UI/Terminal/TerminalTheme+AppKit.swift`:
  ```swift
  import AppKit; import SwiftUI; import AppCore; import SwiftTerm
  extension RGBColor {
      var nsColor: NSColor            // NSColor(srgbRed:green:blue:alpha: 1)
      var swiftUIColor: SwiftUI.Color // Color(.sRGB, red:green:blue:)
      var swiftTermColor: SwiftTerm.Color // SwiftTerm.Color(red8:green8:blue8:) — UInt16(component)
  }
  extension TerminalTheme {
      var swiftTermPalette: [SwiftTerm.Color] { ansi.map(\.swiftTermColor) }
  }
  ```
  In `SwiftTermView.swift` delete `struct TerminalTheme` and make `SessionTerminalView.applyTheme()` use `TerminalThemeCatalog.shared.automatic(prefersDark: dark)` (bg/fg/caret/selection + `installColors(theme.swiftTermPalette)`); `TerminalTabView`'s `.background(TerminalTheme.dynamicBackground)` becomes a dynamic `NSColor(name:)` over the two catalog backgrounds (add `static func dynamicAutomaticBackground() -> SwiftUI.Color` in the adapter file). Add `let terminalSettings = TerminalSettings()` to `AppEnvironment` (doc comment "Per-Mac terminal preferences (Settings → Terminal)"). Mac check by Cory later; on Linux run package tests only. Commit `feat(app): terminal colors come from the theme catalog`.
- [ ] **1.8** Full package test run green. Push branch `m5-core` (Cory pushes; give plain commands).

---

## Task 2 — Settings → Terminal pane (Wave 2)

Worktree: `git worktree add ../wt-m5-settings -b m5-settings m5-core`.

### Signatures

```swift
// AppCore/ViewModels/SettingsPane.swift
case terminal   // after .connection; title "Terminal"; systemImage "terminal"

// App/Sources/UI/Settings/TerminalSettingsPane.swift (new)
struct TerminalSettingsPane: View {
    let settings: TerminalSettings
    var catalog: TerminalThemeCatalog = .shared
}
/// Gallery card: swatch + name + "Light"/"Dark". `theme == nil` = Automatic.
struct ThemeCard: View {
    let theme: TerminalTheme?
    let isSelected: Bool
    let select: () -> Void
}
/// Background fill, a foreground bar (60 % width), bars in ansi[1...5], a cursor block.
/// Automatic draws Reimagined Light and Dark split on the diagonal.
struct ThemeSwatch: View {
    let theme: TerminalTheme?
    var height: CGFloat = 64
}
struct TextSizeStepper: View { let settings: TerminalSettings }   // [−] value [+]
struct ThemeCreditsSheet: View { let catalog: TerminalThemeCatalog } // list + notices text
```

### Steps

- [ ] **2.1** Update `BadgeImageRulesTests.testSettingsPanes`: `allCases == [.connection, .terminal, .sync, .onePassword, .osIcons]`, `SettingsPane.terminal.title == "Terminal"`, `systemImage == "terminal"`. Run → fail. Add the case. Run → pass. Commit `feat(core): Settings → Terminal pane entry`.
- [ ] **2.2** `TerminalSettingsPane` layout per spec §9.1: header "Terminal" (22 pt semibold); "Text Size" row with `TextSizeStepper` (buttons `minus`/`plus` SF Symbols, `.disabled(!settings.canDecreaseFontSize)` etc., value in monospaced digits, accessibility label "Text size, 13 points", `.accessibilityAdjustableAction` maps increment/decrement); "Theme" section `LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16)` with Automatic first, then `catalog.themes`; footer copy exactly: "Applies to every open tab now. A host or group with its own theme keeps it. Saved on this Mac only." and a `Button("Theme credits…")` presenting `ThemeCreditsSheet`.
- [ ] **2.3** `ThemeCard`: `Theme.cardBackground`, corner `Theme.cardCornerRadius`, 2 pt `Theme.accent` stroke when selected, `.help` = "<name> — by <author>, <license>" for credited themes, `.accessibilityAddTraits(isSelected ? .isSelected : [])`, `.accessibilityLabel(name)`; tapping calls `settings.defaultThemeID = theme?.id`.
- [ ] **2.4** `SettingsView`: add `terminalSettings: TerminalSettings` property and `case .terminal: TerminalSettingsPane(settings: terminalSettings)`; `TermiusReimaginedApp` passes `environment.terminalSettings`; update the Settings scene comment listing panes.
- [ ] **2.5** `ThemeCreditsSheet`: for each `catalog.credits` row "Project — Author (License)" + link; below, a scrollable monospaced `Text(TerminalThemeCatalog.noticesText)` with text selection; "Done" button.
- [ ] **2.6** Mac check (Cory): pane shows 21 cards in two columns, selection ring moves, stepper bounds 9/24, credits sheet opens. Commit `feat(app): Settings → Terminal pane with theme gallery and text size`.

---

## Task 3 — Host Details and group theme pickers (Wave 2)

Worktree: `git worktree add ../wt-m5-pickers -b m5-pickers m5-core`.

### Signatures

```swift
// AppCore/ViewModels/HostDetailsViewModel.swift
/// nil = Default (inherit). Saves at once, like the other fields.
public var themeID: String? { get set }
/// What "Default" resolves to from the host's groups: a known theme id, or nil = the app default.
public var inheritedThemeID: String? { get }
/// The stored id when this build's catalog doesn't know it (shown as "Unknown theme (<id>)").
public var unknownThemeID: String? { get }

// AppCore/ViewModels/HostsViewModel.swift
public func themeID(ofGroup id: UUID) -> String?
/// nil = Default. A missing or deleted group is left alone. Saves through the vault (syncs).
public func setTheme(_ themeID: String?, forGroup id: UUID) async throws
/// What "Default" resolves to from the group's parents (nil = the app default).
public func inheritedThemeID(ofGroup id: UUID) -> String?

// App/Sources/UI/Hosts/ThemePicker.swift (new)
/// Menu picker: "Default (<inherited name>)", divider, every catalog theme with a background dot.
struct ThemePicker: View {
    @Binding var themeID: String?
    /// Name shown in "Default (…)": e.g. "Nord — from group", or "Automatic" / the app default's name.
    let defaultLabel: String
    var unknownThemeID: String? = nil
    var catalog: TerminalThemeCatalog = .shared
}
/// The "Theme" submenu for a group card's context menu.
struct GroupThemeMenu: View {
    let currentThemeID: String?
    let select: (String?) -> Void
    var catalog: TerminalThemeCatalog = .shared
}
```

### Steps

- [ ] **3.1** `HostDetailsViewModelTests`: `testThemeIDDefaultsToNil`, `testSettingThemeIDSavesImmediately` (persisted record has the id after `flush`), `testSettingThemeIDNilClearsIt`, `testInheritedThemeIDFromGroup`, `testInheritedThemeIDIgnoresUnknownGroupTheme`, `testUnknownThemeIDReportedForUnknownStoredID`, `testThemeIDOnDeletedHostIsIgnored`. Run → fail. Implement via `update { $0.themeID = newValue }` and `TerminalThemeResolver.inheritedThemeID`. Pass. Commit `feat(core): host theme in HostDetailsViewModel`.
- [ ] **3.2** `HostsViewModelTests`: `testSetGroupThemeSaves`, `testSetGroupThemeNilClears`, `testSetGroupThemeOnMissingGroupDoesNothing`, `testInheritedGroupThemeFromParent`, `testThemeIDOfGroup`. Implement. Commit `feat(core): group default theme in HostsViewModel`.
- [ ] **3.3** `HostDetailsPanel`: replace the disabled "Show more" with `@State private var showsMore = false` and a link-style toggle "Show more"/"Show less"; when open, a `DetailsCard` titled "Terminal" with `FieldColumn(title: "Theme") { ThemePicker(themeID: $details.themeID, defaultLabel: …, unknownThemeID: details.unknownThemeID) }`. `defaultLabel`: inherited id → "<name> — from group"; else the app default → its name, or "Automatic". The panel needs `TerminalSettings` for that label: add `let terminalSettings: TerminalSettings` to `HostDetailsPanel`/`HostDetailsContent` and pass it from `HostsView` (which gets it from `MainArea`/`ReadyArea` — add the parameter along that chain; `RootView.swift` is owned by Task 4, so here only add the parameter to `HostsView` and leave a `// Task 4 passes environment.terminalSettings` note; Task 5 resolves the one-line merge in `RootView`).
- [ ] **3.4** `HostsView` group card `.contextMenu`: add `Menu("Theme") { GroupThemeMenu(currentThemeID: model.themeID(ofGroup: group.id)) { id in Task { try? await model.setTheme(id, forGroup: group.id) } } }` above Rename; checkmark on the current choice; "Default" first.
- [ ] **3.5** Mac check (Cory): new host → Show more → Theme lists Default + 20; choosing saves; group menu sets the default; a host on "Default" shows "<group theme> — from group". Commit `feat(app): theme pickers in Host Details and group menu`.

---

## Task 4 — Live apply in terminal tabs (Wave 2)

Worktree: `git worktree add ../wt-m5-live -b m5-live m5-core`.

### Signatures

```swift
// AppCore/Sessions/SessionManager.swift (TerminalTab)
/// The saved host this tab connects to; nil for quick connect.
public var savedHostID: UUID? { hostID }

// App/Sources/UI/Terminal/SwiftTermView.swift
struct SwiftTermView: NSViewRepresentable {
    let tab: TerminalTab
    let sessions: SessionManager
    let store: TerminalViewStore
    let appearance: TerminalAppearance
}
@MainActor final class TerminalViewStore {
    func view(for tab: TerminalTab, sessions: SessionManager, appearance: TerminalAppearance) -> SessionTerminalView
}
final class SessionTerminalView: TerminalView {
    /// Installs palette, bg/fg/caret/selection; sets the font only when the size changed.
    /// Returns early when `appearance` equals the last applied one.
    func apply(_ appearance: TerminalAppearance)
}

// App/Sources/UI/Terminal/TerminalTabView.swift
struct TerminalTabView: View {
    let tab: TerminalTab
    let sessions: SessionManager
    let store: TerminalViewStore
    let vault: LocalVault
    let terminalSettings: TerminalSettings
    let closeTab: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var appearance: TerminalAppearance   // via TerminalThemeResolver
}
```

### Steps

- [ ] **4.1** `SessionManagerTests`: `testSavedHostIDForHostTab`, `testSavedHostIDNilForQuickConnect`. Run → fail. Add the property. Pass. Commit `feat(core): TerminalTab.savedHostID`.
- [ ] **4.2** `TerminalTabView.appearance`: `_ = vault.revision`; `TerminalThemeResolver.theme(forHostID: tab.savedHostID, hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self), defaultThemeID: terminalSettings.defaultThemeID, prefersDark: colorScheme == .dark)` and `fontSize: terminalSettings.fontSize`. Background around the terminal = `appearance.theme.background.swiftUIColor`. Pass `appearance` to `SwiftTermView`.
- [ ] **4.3** `SwiftTermView.makeNSView`/`updateNSView`: `let view = store.view(for: tab, sessions: sessions, appearance: appearance); view.apply(appearance); host.attach(view)`. `TerminalBridge.init` takes the initial font size (`NSFont.monospacedSystemFont(ofSize: CGFloat(appearance.fontSize), weight: .regular)`).
- [ ] **4.4** `SessionTerminalView`: remove `applyTheme()`, `appliedDarkTheme`, and the `viewDidChangeEffectiveAppearance`/`viewDidMoveToWindow` re-theming (Automatic now comes from `colorScheme`). Add `private var appliedAppearance: TerminalAppearance?` and `apply(_:)`: `installColors(theme.swiftTermPalette)`, `nativeBackgroundColor`, `nativeForegroundColor`, `caretColor = theme.cursor.nsColor`, `selectedTextBackgroundColor = theme.selection.nsColor`; if `appliedAppearance?.fontSize != fontSize` set `font`. The font change goes through SwiftTerm's resize → `sizeChanged` → `reportSize` → `SessionManager.resize` as today.
- [ ] **4.5** `RootView.ReadyArea`: pass `vault` and `environment.terminalSettings` to `TerminalTabView`; pass `environment.terminalSettings` down `MainArea` → `HostsView` (parameter added by Task 3; if Task 3 isn't merged yet, Task 5 adds the one argument).
- [ ] **4.6** Mac check (Cory): with a tab open, change the Settings theme → tab re-colors immediately, scrollback re-colored; change text size → grid reflows and `stty size` on the remote changes; switch macOS Light/Dark with Automatic → tab follows; set a host theme in Host Details while its tab is open → tab follows on return to it; a quick-connect tab uses the app default; a sync from the other Mac changing the host's theme re-colors the tab. Commit `feat(app): terminal tabs follow theme and text size live`.

---

## Task 5 — Merge, version, README, checkpoint (Wave 3)

- [ ] **5.1** In `m5-themes`: merge `m5-core`, then `m5-settings`, `m5-pickers`, `m5-live` (resolve the one-line `RootView`/`HostsView` parameter hand-off from Tasks 3/4). Full package tests green on Linux.
- [ ] **5.2** `App/project.yml`: `MARKETING_VERSION: "0.6.0"`. Commit `chore(app): version 0.6.0`.
- [ ] **5.3** `README.md`: Settings → Terminal and per-host/group themes under features; a "Third-party themes" line: "Bundled terminal themes are MIT-licensed by their authors; see `Packages/CoreSSH/Sources/AppCore/Resources/terminal-themes-notices.txt` (also in Settings → Terminal → Theme credits)." Commit `docs: terminal themes in README`.
- [ ] **5.4** Mac checkpoint with Cory (all Task 2–4 checks, plus: sidebar shows `v0.6.0 (<commit>)`; existing hosts look unchanged on Automatic). Then merge `m5-themes` into `main` with a merge commit "Merge milestone 5: terminal themes (v0.6.0)". Give Cory the plain git commands to push.

---

## Appendix A — `terminal-themes.json` (commit verbatim)

Generated 2026-11-14 from the upstream files named in each credit (`files`). Originals: `reimagined-*` (app palette), `hacker-*` (single-hue HSV ramp: hue 210°/135°/0°).

```json
{
  "version": 1,
  "credits": {
    "flexoki": {"project": "Flexoki", "author": "Steph Ango", "license": "MIT", "copyright": "Copyright (c) 2023 Steph Ango", "url": "https://github.com/kepano/flexoki", "files": "kitty/flexoki_dark.conf, kitty/flexoki_light.conf"},
    "kanagawa": {"project": "Kanagawa", "author": "Tommaso Laurenzi", "license": "MIT", "copyright": "Copyright (c) 2021 Tommaso Laurenzi", "url": "https://github.com/rebelot/kanagawa.nvim", "files": "extras/alacritty/*.toml; cursor from extras/ghostty, extras/kitty"},
    "everforest": {"project": "Everforest", "author": "sainnhe", "license": "MIT", "copyright": "Copyright (c) 2019 sainnhe", "url": "https://github.com/sainnhe/everforest", "files": "autoload/everforest.vim medium palette; colors/everforest.vim terminal mapping"},
    "night-owl": {"project": "Night Owl", "author": "Sarah Drasner", "license": "MIT", "copyright": "Copyright (c) 2018 Sarah Drasner", "url": "https://github.com/sdras/night-owl-vscode-theme", "files": "themes/Night Owl-color-theme.json, themes/Night Owl-Light-color-theme.json"},
    "rose-pine": {"project": "Rosé Pine", "author": "Rosé Pine", "license": "MIT", "copyright": "Copyright (c) Rosé Pine", "url": "https://github.com/rose-pine/alacritty", "files": "dist/rose-pine.toml"},
    "aura": {"project": "Aura Theme", "author": "Dalton Menezes", "license": "MIT", "copyright": "Copyright (c) 2021 - * Dalton Menezes", "url": "https://github.com/daltonmenezes/aura-theme", "files": "packages/alacritty/aura-theme.toml"},
    "dracula": {"project": "Dracula", "author": "Dracula Theme", "license": "MIT", "copyright": "Copyright (c) 2018 Dracula Theme", "url": "https://github.com/dracula/alacritty", "files": "dracula.toml"},
    "solarized": {"project": "Solarized", "author": "Ethan Schoonover", "license": "MIT", "copyright": "Copyright (c) 2011 Ethan Schoonover", "url": "https://github.com/altercation/solarized", "files": "palette and terminal mapping in README"},
    "nord": {"project": "Nord", "author": "Sven Greb", "license": "MIT", "copyright": "Copyright (c) 2016-present Sven Greb <development@svengreb.de> (https://www.svengreb.de)", "url": "https://github.com/nordtheme/alacritty", "files": "src/nord.yaml"}
  },
  "themes": [
    {"id": "reimagined-light", "name": "Reimagined Light", "appearance": "light", "credit": null,
     "background": "#EEF0F2", "foreground": "#1F2328", "cursor": "#3B82F6", "selection": "#B6D2FB",
     "ansi": ["#1F2328", "#C8323A", "#1E8A4C", "#9A6A00", "#2563EB", "#8B3FD1", "#0E7F93", "#8A919C",
              "#5E6673", "#E5484D", "#2DA160", "#B7860B", "#3B82F6", "#A855F7", "#1597AE", "#D5D9DF"]},
    {"id": "reimagined-dark", "name": "Reimagined Dark", "appearance": "dark", "credit": null,
     "background": "#1B1D2A", "foreground": "#E4E6EB", "cursor": "#6CA2F8", "selection": "#3A4A6B",
     "ansi": ["#2A2D3E", "#F0656B", "#5FCB8A", "#E8C468", "#6CA2F8", "#C08CF0", "#4FC6D8", "#C9CDD6",
              "#5C6378", "#FF8A8F", "#84E0A7", "#F5D88E", "#93BBFF", "#D5AEFA", "#7FDAE6", "#F4F5F8"]},
    {"id": "flexoki-dark", "name": "Flexoki Dark", "appearance": "dark", "credit": "flexoki",
     "background": "#100F0F", "foreground": "#CECDC3", "cursor": "#CECDC3", "selection": "#403E3C",
     "ansi": ["#100F0F", "#AF3029", "#66800B", "#AD8301", "#205EA6", "#A02F6F", "#24837B", "#878580",
              "#6F6E69", "#D14D41", "#879A39", "#D0A215", "#4385BE", "#CE5D97", "#3AA99F", "#CECDC3"]},
    {"id": "flexoki-light", "name": "Flexoki Light", "appearance": "light", "credit": "flexoki",
     "background": "#FFFCF0", "foreground": "#100F0F", "cursor": "#100F0F", "selection": "#CECDC3",
     "ansi": ["#100F0F", "#D14D41", "#879A39", "#D0A215", "#4385BE", "#CE5D97", "#3AA99F", "#FFFCF0",
              "#6F6E69", "#AF3029", "#66800B", "#AD8301", "#205EA6", "#A02F6F", "#24837B", "#F2F0E5"]},
    {"id": "kanagawa-wave", "name": "Kanagawa Wave", "appearance": "dark", "credit": "kanagawa",
     "background": "#1F1F28", "foreground": "#DCD7BA", "cursor": "#C8C093", "selection": "#2D4F67",
     "ansi": ["#090618", "#C34043", "#76946A", "#C0A36E", "#7E9CD8", "#957FB8", "#6A9589", "#C8C093",
              "#727169", "#E82424", "#98BB6C", "#E6C384", "#7FB4CA", "#938AA9", "#7AA89F", "#DCD7BA"]},
    {"id": "kanagawa-dragon", "name": "Kanagawa Dragon", "appearance": "dark", "credit": "kanagawa",
     "background": "#181616", "foreground": "#C5C9C5", "cursor": "#C8C093", "selection": "#2D4F67",
     "ansi": ["#0D0C0C", "#C4746E", "#8A9A7B", "#C4B28A", "#8BA4B0", "#A292A3", "#8EA4A2", "#C8C093",
              "#A6A69C", "#E46876", "#87A987", "#E6C384", "#7FB4CA", "#938AA9", "#7AA89F", "#C5C9C5"]},
    {"id": "kanagawa-lotus", "name": "Kanagawa Lotus", "appearance": "light", "credit": "kanagawa",
     "background": "#F2ECBC", "foreground": "#545464", "cursor": "#43436C", "selection": "#C9CBD1",
     "ansi": ["#1F1F28", "#C84053", "#6F894E", "#77713F", "#4D699B", "#B35B79", "#597B75", "#545464",
              "#8A8980", "#D7474B", "#6E915F", "#836F4A", "#6693BF", "#624C83", "#5E857A", "#43436C"]},
    {"id": "everforest-dark", "name": "Everforest Dark", "appearance": "dark", "credit": "everforest",
     "background": "#2D353B", "foreground": "#D3C6AA", "cursor": "#D3C6AA", "selection": "#543A48",
     "ansi": ["#475258", "#E67E80", "#A7C080", "#DBBC7F", "#7FBBB3", "#D699B6", "#83C092", "#D3C6AA",
              "#475258", "#E67E80", "#A7C080", "#DBBC7F", "#7FBBB3", "#D699B6", "#83C092", "#D3C6AA"]},
    {"id": "everforest-light", "name": "Everforest Light", "appearance": "light", "credit": "everforest",
     "background": "#FDF6E3", "foreground": "#5C6A72", "cursor": "#5C6A72", "selection": "#EAEDC8",
     "ansi": ["#5C6A72", "#F85552", "#8DA101", "#DFA000", "#3A94C5", "#DF69BA", "#35A77C", "#E6E2CC",
              "#5C6A72", "#F85552", "#8DA101", "#DFA000", "#3A94C5", "#DF69BA", "#35A77C", "#E6E2CC"]},
    {"id": "night-owl", "name": "Night Owl", "appearance": "dark", "credit": "night-owl",
     "background": "#011627", "foreground": "#D6DEEB", "cursor": "#80A4C2", "selection": "#1D3B53",
     "ansi": ["#011627", "#EF5350", "#22DA6E", "#C5E478", "#82AAFF", "#C792EA", "#21C7A8", "#FFFFFF",
              "#575656", "#EF5350", "#22DA6E", "#FFEB95", "#82AAFF", "#C792EA", "#7FDBCA", "#FFFFFF"]},
    {"id": "light-owl", "name": "Light Owl", "appearance": "light", "credit": "night-owl",
     "background": "#F6F6F6", "foreground": "#403F53", "cursor": "#90A7B2", "selection": "#E0E0E0",
     "ansi": ["#403F53", "#DE3D3B", "#08916A", "#E0AF02", "#288ED7", "#D6438A", "#2AA298", "#93A1A1",
              "#403F53", "#DE3D3B", "#08916A", "#DAAA01", "#288ED7", "#D6438A", "#2AA298", "#93A1A1"]},
    {"id": "rose-pine", "name": "Rosé Pine", "appearance": "dark", "credit": "rose-pine",
     "background": "#191724", "foreground": "#E0DEF4", "cursor": "#524F67", "selection": "#403D52",
     "ansi": ["#26233A", "#EB6F92", "#31748F", "#F6C177", "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
              "#6E6A86", "#EB6F92", "#31748F", "#F6C177", "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4"]},
    {"id": "aura", "name": "Aura", "appearance": "dark", "credit": "aura",
     "background": "#15141B", "foreground": "#EDECEE", "cursor": "#A277FF", "selection": "#29263C",
     "ansi": ["#110F18", "#FF6767", "#61FFCA", "#FFCA85", "#A277FF", "#A277FF", "#61FFCA", "#EDECEE",
              "#4D4D4D", "#FF6767", "#61FFCA", "#FFCA85", "#A277FF", "#A277FF", "#61FFCA", "#EDECEE"]},
    {"id": "dracula", "name": "Dracula", "appearance": "dark", "credit": "dracula",
     "background": "#282A36", "foreground": "#F8F8F2", "cursor": "#F8F8F2", "selection": "#44475A",
     "ansi": ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
              "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]},
    {"id": "solarized-dark", "name": "Solarized Dark", "appearance": "dark", "credit": "solarized",
     "background": "#002B36", "foreground": "#839496", "cursor": "#93A1A1", "selection": "#073642",
     "ansi": ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
              "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]},
    {"id": "solarized-light", "name": "Solarized Light", "appearance": "light", "credit": "solarized",
     "background": "#FDF6E3", "foreground": "#657B83", "cursor": "#586E75", "selection": "#EEE8D5",
     "ansi": ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
              "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]},
    {"id": "nord", "name": "Nord", "appearance": "dark", "credit": "nord",
     "background": "#2E3440", "foreground": "#D8DEE9", "cursor": "#D8DEE9", "selection": "#4C566A",
     "ansi": ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
              "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]},
    {"id": "hacker-blue", "name": "Hacker Blue", "appearance": "dark", "credit": null,
     "background": "#03070A", "foreground": "#3399FF", "cursor": "#3399FF", "selection": "#13304C",
     "ansi": ["#08111A", "#185B9E", "#1470CC", "#67A6E6", "#194C80", "#407CB8", "#61AAF2", "#98B8D9",
              "#213952", "#327CC7", "#3399FF", "#99CCFF", "#326DA8", "#70A8E0", "#99CCFF", "#E6F2FF"]},
    {"id": "hacker-green", "name": "Hacker Green", "appearance": "dark", "credit": null,
     "background": "#030A05", "foreground": "#33FF66", "cursor": "#33FF66", "selection": "#134C21",
     "ansi": ["#081A0C", "#189E39", "#14CC42", "#67E687", "#198033", "#40B85E", "#61F285", "#98D9A8",
              "#21522D", "#32C757", "#33FF66", "#99FFB2", "#32A850", "#70E08C", "#99FFB2", "#E6FFEC"]},
    {"id": "hacker-red", "name": "Hacker Red", "appearance": "dark", "credit": null,
     "background": "#0A0303", "foreground": "#FF3333", "cursor": "#FF3333", "selection": "#4C1313",
     "ansi": ["#1A0808", "#9E1818", "#CC1414", "#E66767", "#801919", "#B84040", "#F26161", "#D99898",
              "#522121", "#C73232", "#FF3333", "#FF9999", "#A83232", "#E07070", "#FF9999", "#FFE6E6"]}
  ]
}
```

## Appendix B — `terminal-themes-notices.txt`

Plain UTF-8 text. First line: `Third-party terminal color themes bundled with Termius Reimagined`. Then, for each credit in the JSON order (flexoki, kanagawa, everforest, night-owl, rose-pine, aura, dracula, solarized, nord), a block:

```
================================================================================
<project> — <url>
Colors taken from: <files>
--------------------------------------------------------------------------------
<the upstream LICENSE file, verbatim>
```

Upstream license files (all MIT, checked 2026-11-14):

| Credit | License file |
|---|---|
| flexoki | https://raw.githubusercontent.com/kepano/flexoki/main/LICENSE |
| kanagawa | https://raw.githubusercontent.com/rebelot/kanagawa.nvim/master/LICENSE |
| everforest | https://raw.githubusercontent.com/sainnhe/everforest/master/LICENSE |
| night-owl | https://raw.githubusercontent.com/sdras/night-owl-vscode-theme/main/LICENSE.md |
| rose-pine | https://raw.githubusercontent.com/rose-pine/alacritty/main/LICENSE |
| aura | https://raw.githubusercontent.com/daltonmenezes/aura-theme/main/LICENSE |
| dracula | https://raw.githubusercontent.com/dracula/alacritty/master/LICENSE |
| solarized | https://raw.githubusercontent.com/altercation/solarized/master/LICENSE |
| nord | https://raw.githubusercontent.com/nordtheme/alacritty/main/license |

The `copyright` string in each JSON credit is the copyright line of that file, so `testEveryCreditIsMITAndAppearsInNotices` holds.

## Appendix C — Themes considered and not bundled

- Termius' own themes and artwork — proprietary; never copied. Our "Hacker" themes are original values.
- `mbadolato/iTerm2-Color-Schemes` as a *source* — MIT, but an aggregator whose values differ from upstream in places; used only to cross-check.
- Nord palette repo (`nordtheme/nord`, Apache-2.0) as the source — fine to bundle, but we use the MIT `nordtheme/alacritty` port to keep one license and no NOTICE file.
- Every candidate on Cory's list passed the license check; none was rejected.
