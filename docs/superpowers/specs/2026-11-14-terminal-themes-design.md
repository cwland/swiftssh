# Milestone 5 — Terminal Themes: Design

Date: 2026-11-14 · Status: proposed, waiting for Cory's answers to the open questions (§11) · Ships as **v0.6.0**

Parent spec: `docs/superpowers/specs/2026-11-13-termius-reimagined-design.md` (§ Data model: Host/HostGroup theme inheritance; § Settings: Terminal; § Milestones: 5).

## 1. Intent

Cory's request, verbatim:

> Settings → Terminal pane, modelled on Termius:
> - Text Size stepper (− / value / +).
> - Terminal theme gallery: two-column grid of cards, each with a small preview swatch drawn from the theme's own colors (background, foreground and a few ANSI colors as bars) and the theme name; the selected theme is highlighted. The chosen theme is the app-wide default and applies to all terminal tabs live.
> - Built-in themes: our own light and dark defaults (in the app's style, not Termius's), plus open-source themes whose licenses allow bundling — candidates: Flexoki Dark/Light, Kanagawa Wave/Dragon/Lotus, Everforest Dark/Light, Night Owl / Light Owl, Rosé Pine, Aura, Dracula, Solarized Dark/Light, Nord, plus simple "Hacker" Blue/Green/Red. Check each theme's license before shipping.
> - Per-host theme: a Theme picker in Host Details (under "Show more"), available when creating a host and when editing one; "Default" means inherit. Uses the existing synced Host.themeID, so it syncs to every Mac. Groups get the same picker (HostGroup.defaultThemeID); a host without its own theme inherits its group's, then the app default (HostDirectory.effectiveThemeID, already built in milestone 1). Changing a host's theme updates its open tabs live.
> - Termius' download counts on each card don't apply here.

## 2. What exists today (read from `main` @ 269ce43)

| Piece | Where | State |
|---|---|---|
| `Host.themeID: String?`, `HostGroup.defaultThemeID: String?` | `Packages/CoreSSH/Sources/CoreModels/Models.swift` | Synced, round-trip tested, never set by the UI. |
| `HostDirectory.effectiveThemeID(for:)` | `CoreModels/HostQueries.swift` | Host → group → parent groups (cycle-safe `firstInChain`). Returns the first non-nil id, *known or not*. |
| Terminal colors | `App/Sources/UI/Terminal/SwiftTermView.swift` — app-local `struct TerminalTheme` (bg/fg/caret/selection only, `.light`/`.dark`) | `SessionTerminalView.applyTheme()` switches on effective appearance. ANSI palette is SwiftTerm's default. |
| Terminal font | `TerminalBridge.terminalFont` | SF Mono 13 pt, hard-coded. |
| Terminal background around the view | `TerminalTabView` → `.background(TerminalTheme.dynamicBackground)` | Appearance-based. |
| Tab → host | `TerminalTab.target` / `hostID` | `fileprivate`; no public way to ask which saved host a tab shows. |
| Only the selected tab is on screen | `RootView.ReadyArea` renders one `TerminalTabView` (`.id(tab.id)`); views live in `TerminalViewStore` | `SwiftTermView.updateNSView` re-attaches the stored view each time. |
| Per-Mac settings pattern | `AppCore/Sessions/ConnectionSettings.swift` | `@MainActor @Observable`, `UserDefaults` keys `connection.*`, "Saved on this Mac only". |
| Bundled-JSON pattern | `AppCore/Catalog/OSCatalog.swift` + `Resources/os-catalog*.json` | `Bundle.module`, `.copy` resources, `static let shared`, lenient parsing. |
| Settings panes | `AppCore/ViewModels/SettingsPane.swift` + `App/Sources/UI/Settings/SettingsView.swift` | `connection, sync, onePassword, osIcons`; test `BadgeImageRulesTests.testSettingsPanes` pins the order. |
| Host Details | `App/Sources/UI/Hosts/HostDetailsPanel.swift` + `AppCore/ViewModels/HostDetailsViewModel.swift` | "Show more" is a disabled link button. A new host is saved first (`HostsViewModel.newHost()`) and then edited in the same panel, so "when creating" and "when editing" are the same screen. |
| Group editing | `HostsView` context menu: Rename / Delete (alerts) | There is no group details panel. |
| SwiftTerm 1.99.3 API used | `installColors(_: [SwiftTerm.Color])` (16 entries, recomputes palette and redraws), `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor`, `selectedTextBackgroundColor`, `font` (setter rebuilds the font set → grid size changes → `sizeChanged` → PTY resize) | Verified in `/tmp/swiftterm-src` at tag v1.99.3. |
| No synced app-settings record | `SyncRecordType`: host, hostGroup, identity, sshKey, snippet, knownHost, connectionLog, shellHistory, aiSettings | A synced app default would need a new record type. |

## 3. Goals

1. Settings → Terminal pane: Text Size stepper and a two-column theme gallery with live swatches; selection = app-wide default; every open tab follows live.
2. A bundled catalog of 20 themes (2 original + 15 open-source + 3 original "Hacker"), each license-checked, with attribution shipped in the app.
3. Per-host Theme picker in Host Details → Show more ("Default" = inherit), per-group picker, both stored in the existing synced fields; open tabs of affected hosts update live.
4. Resolution that never breaks: unknown or missing ids fall through to the next level, and finally to the app default.
5. Everything outside SwiftUI/AppKit is TDD'd in `Packages/CoreSSH` and runs on Linux (`swift test -Xlinker --allow-shlib-undefined`).

## 4. Non-goals (this milestone)

- Importing or editing custom themes (`.itermcolors`, Ghostty, etc.).
- Font family choice, line height, ligatures, bold-as-bright, cursor style, copy-on-select (the parent spec lists font and copy-on-select under Settings → Terminal; they can join this pane later).
- The terminal's right-hand drawer "Theme & Font" (parent spec §8) — later milestone, reuses this catalog.
- Per-host text size.
- Termius' download counts, ratings or any Termius artwork, names or colors.
- Changing the app chrome (top bar, sidebar) to match the terminal theme.
- Cmd+= / Cmd+− zoom shortcuts (see open question Q5).

## 5. Approaches considered

### 5.1 Where theme data lives

| Option | Pros | Cons |
|---|---|---|
| **A. Bundled JSON resource in AppCore (`Resources/terminal-themes.json`) parsed into `TerminalTheme` values** — recommended | Same pattern as `OSCatalog`; data is reviewable and diffable; tests can load alternative JSON; licenses/credits sit beside the data; future import of user themes reuses the parser. | A little parsing code; must validate (16 ANSI entries, valid hex). |
| B. Swift literals (`static let dracula = TerminalTheme(...)`) | No parsing, compile-time checked. | 20 × 20 color literals in code; credits drift from data; no path to user themes. |
| C. Ship third-party theme files (alacritty/kitty) and parse several formats | "Exact upstream file." | Multiple parsers; formats differ in what they define (Aura has no selection fg, Kanagawa alacritty has no cursor); more surface for bugs. |

**Recommendation: A.** The JSON is generated once from the upstream sources listed in §8 and committed; the full content is in the implementation plan (Task 1).

### 5.2 How tabs follow changes live

| Option | Pros | Cons |
|---|---|---|
| **A. SwiftUI-driven: `TerminalTabView` computes a `TerminalAppearance` (theme + font size) through an AppCore resolver that reads `vault.revision`, `TerminalSettings` and the color scheme; `SwiftTermView.updateNSView` calls `SessionTerminalView.apply(_:)`, which no-ops when unchanged** — recommended | Uses Observation already in place (`LocalVault` and settings are `@Observable`); no extra notification plumbing; only the visible tab is on screen, and a hidden tab is re-themed in `updateNSView` when it is shown (before it draws), which is indistinguishable from live. Synced changes from another Mac arrive through `vault.revision` too. | The resolver must be cheap (it runs on every body evaluation): it is — a dictionary build over hosts/groups, or cache by `vault.revision`. |
| B. `TerminalViewStore` subscribes with `withObservationTracking` and pushes to every stored view | Hidden views update immediately. | Re-arming observation loops by hand; more code, harder to test, no visible benefit. |
| C. NotificationCenter "theme changed" posts | Familiar. | Misses synced changes unless every write path posts; easy to forget. |

**Recommendation: A.**

### 5.3 Where the app default and text size are stored

| Option | Pros | Cons |
|---|---|---|
| **A. Per Mac, `UserDefaults` (`terminal.defaultThemeID`, `terminal.fontSize`) in a new `TerminalSettings` like `ConnectionSettings`** — recommended | Matches the existing pattern and copy ("Saved on this Mac only"); text size depends on each Mac's display (Mac mini on a big monitor vs MacBook Pro); no sync schema change. Per-host and per-group themes still sync, which covers "same look for a host on every Mac". | Picking a new app default on one Mac does not carry over (Q1). |
| B. Synced: new `SyncRecordType.appSettings` record | Default theme is the same everywhere. | Server/wire change, merge rules, migration; text size should *not* sync anyway, so one record would hold mixed scopes. |

**Recommendation: A** for both. If Cory wants the default theme synced, it can move to a synced record later without changing the host/group fields.

### 5.4 Group picker UI (no group details panel exists)

| Option | Pros | Cons |
|---|---|---|
| **A. Group card context menu → "Theme" submenu: "Default" + catalog names with a checkmark** — recommended for M5 | Small; fits existing Rename/Delete menu; no new screen. | No swatch preview in a menu (names only). |
| B. A Group Details panel (name, default port, identity, theme) like Host Details | Termius-like; room for future group defaults. | A whole new panel; scope creep for this milestone. |

**Recommendation: A**, with B as a possible later milestone (Q3).

## 6. Data model

### 6.1 Synced (unchanged schema)

- `Host.themeID: String?` — nil = "Default" (inherit).
- `HostGroup.defaultThemeID: String?` — nil = "Default" (inherit from parent group, then app default).
- Values are catalog ids (stable slugs, §7). No migration: nothing writes them today.

### 6.2 New in CoreModels

```swift
extension HostDirectory {
    /// Theme ids from nearest to farthest: the host's own, then each group up the parent chain
    /// (cycle-safe, deleted groups skipped). nil levels are omitted.
    public func themeIDChain(for host: Host) -> [String]
}
```

`effectiveThemeID(for:)` stays as is (it is `themeIDChain(for:).first`). The chain exists so a resolver can skip ids the catalog does not know (e.g. a theme added in a newer build on another Mac, or a removed theme) and fall to the next level instead of jumping straight to the app default.

### 6.3 New in AppCore (`Sources/AppCore/Terminal/`)

- `RGBColor` — `red/green/blue: UInt8`, `init?(hex:)` ("#RRGGBB" or "RRGGBB", case-insensitive), `hex` ("#RRGGBB" uppercase), `relativeLuminance` (WCAG), `contrastRatio(with:)` — used by data-sanity tests (dark backgrounds < 0.05 luminance, light > 0.8, fg/bg contrast ≥ 4.0; Solarized Light is the lowest at 4.13).
- `TerminalTheme` — `id`, `name`, `appearance: .light | .dark`, `background`, `foreground`, `cursor`, `selection`, `ansi: [RGBColor]` (exactly 16), `credit: ThemeCredit?`.
- `ThemeCredit` — `key`, `project`, `author`, `license`, `copyright`, `url`, `files` (which upstream files the values came from).
- `TerminalThemeCatalog` — `static let shared`, `init(jsonData:) throws`, `themes` (in JSON order = gallery order), `theme(id:)`, `contains(_:)`, `credits` (unique, ordered). Strict on bundled data (tests fail on any bad entry); at runtime a malformed entry is skipped rather than crashing.
- `TerminalThemeChoice` constants: `TerminalThemeCatalog.lightDefaultID = "reimagined-light"`, `darkDefaultID = "reimagined-dark"`.
- `TerminalSettings` (`@MainActor @Observable`, `UserDefaults`):
  - `defaultThemeID: String?` — nil = **Automatic** (Reimagined Light in Aqua, Reimagined Dark in Dark Aqua — today's behaviour, so nothing changes for Cory until he picks). An unknown stored id reads as nil.
  - `fontSize: Int` — default 13, range 9…24, step 1; out-of-range stored values are clamped; `increaseFontSize()`, `decreaseFontSize()`, `canIncrease`, `canDecrease`.
- `TerminalAppearance: Equatable, Sendable` — `theme: TerminalTheme`, `fontSize: Int`.
- `TerminalThemeResolver` — pure function:
  `theme(forHostID: UUID?, hosts: [SavedHost], groups: [HostGroup], defaultThemeID: String?, prefersDark: Bool, catalog: TerminalThemeCatalog) -> TerminalTheme`:
  first *known* id in `themeIDChain`, else `defaultThemeID` if known, else Automatic by `prefersDark`. Quick-connect tabs (no saved host) and deleted hosts use the app default.
- `TerminalTab.savedHostID: UUID?` — public read-only view of the existing `fileprivate hostID`.
- `HostDetailsViewModel.themeID: String?` (get/set, saves at once like other fields) and `inheritedThemeID: String?` (first known id from the host's group chain, ignoring the host's own; nil = app default).
- `HostsViewModel.themeID(ofGroup:) -> String?` and `setTheme(_ themeID: String?, forGroup id: UUID) async throws`.
- `SettingsPane.terminal` — title "Terminal", SF Symbol `terminal`, placed second: `[.connection, .terminal, .sync, .onePassword, .osIcons]`.

### 6.4 App

- Delete the app-local `struct TerminalTheme`; add `TerminalTheme`/`RGBColor` → `NSColor`/`SwiftUI.Color`/`SwiftTerm.Color` conversions in `App/Sources/UI/Terminal/TerminalTheme+AppKit.swift`.
- `SessionTerminalView.apply(_ appearance: TerminalAppearance)`: sets `installColors(ansi)`, `nativeBackgroundColor`, `nativeForegroundColor`, `caretColor`, `selectedTextBackgroundColor`, and `font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)` only when the size changed; remembers the last applied value and returns early when equal. The appearance-change override is removed (Automatic is resolved from SwiftUI's `colorScheme`).
- `TerminalTabView` background uses the resolved theme's background.
- `AppEnvironment.terminalSettings = TerminalSettings()`; passed to `SettingsView` and `ReadyArea`/`TerminalTabView`.

## 7. Theme catalog

Gallery order (JSON order) and ids. Ids are stored in synced records, so they never change once shipped.

| # | id | Name | Appearance | Source of colors | License |
|---|---|---|---|---|---|
| 1 | `reimagined-light` | Reimagined Light | light | Original (app tokens: bg #EEF0F2, accent #3B82F6) | ours |
| 2 | `reimagined-dark` | Reimagined Dark | dark | Original (current dark bg #1B1D2A) | ours |
| 3 | `flexoki-dark` | Flexoki Dark | dark | kepano/flexoki `kitty/flexoki_dark.conf` | MIT, © 2023 Steph Ango |
| 4 | `flexoki-light` | Flexoki Light | light | kepano/flexoki `kitty/flexoki_light.conf` | MIT, © 2023 Steph Ango |
| 5 | `kanagawa-wave` | Kanagawa Wave | dark | rebelot/kanagawa.nvim `extras/alacritty/kanagawa_wave.toml` (+ cursor from `extras/ghostty/kanagawa-wave`) | MIT, © 2021 Tommaso Laurenzi |
| 6 | `kanagawa-dragon` | Kanagawa Dragon | dark | `extras/alacritty/kanagawa_dragon.toml` (+ cursor from `extras/kitty/kanagawa_dragon.conf`) | MIT, © 2021 Tommaso Laurenzi |
| 7 | `kanagawa-lotus` | Kanagawa Lotus | light | `extras/alacritty/kanagawa_lotus.toml` (+ cursor from `extras/ghostty/kanagawa-lotus`) | MIT, © 2021 Tommaso Laurenzi |
| 8 | `everforest-dark` | Everforest Dark | dark | sainnhe/everforest `autoload/everforest.vim` (medium contrast) + terminal mapping in `colors/everforest.vim` | MIT, © 2019 sainnhe |
| 9 | `everforest-light` | Everforest Light | light | same, light/medium | MIT, © 2019 sainnhe |
| 10 | `night-owl` | Night Owl | dark | sdras/night-owl-vscode-theme `themes/Night Owl-color-theme.json` (`terminal.ansi*`, `editor.*`) | MIT, © 2018 Sarah Drasner |
| 11 | `light-owl` | Light Owl | light | `themes/Night Owl-Light-color-theme.json` | MIT, © 2018 Sarah Drasner |
| 12 | `rose-pine` | Rosé Pine | dark | rose-pine/alacritty `dist/rose-pine.toml` | MIT, © Rosé Pine |
| 13 | `aura` | Aura | dark | daltonmenezes/aura-theme `packages/alacritty/aura-theme.toml` | MIT, © 2021 - * Dalton Menezes |
| 14 | `dracula` | Dracula | dark | dracula/alacritty `dracula.toml` | MIT, © 2018 Dracula Theme |
| 15 | `solarized-dark` | Solarized Dark | dark | altercation/solarized palette + README terminal mapping | MIT, © 2011 Ethan Schoonover |
| 16 | `solarized-light` | Solarized Light | light | same | MIT, © 2011 Ethan Schoonover |
| 17 | `nord` | Nord | dark | nordtheme/alacritty `src/nord.yaml` (MIT port; the palette repo itself is Apache-2.0 — we take the MIT port to avoid NOTICE handling) | MIT, © 2016-present Sven Greb |
| 18 | `hacker-blue` | Hacker Blue | dark | Original (one-hue ramp, hue 210°) | ours |
| 19 | `hacker-green` | Hacker Green | dark | Original (hue 135°) | ours |
| 20 | `hacker-red` | Hacker Red | dark | Original (hue 0°) | ours |

Faithfulness rule: open-source themes use the upstream terminal port's values exactly, including choices that look odd (Aura and Rosé Pine have bright = normal; Everforest maps bright = normal; Flexoki Light's white equals its background). Where a port defines no cursor or selection, the table above names where it came from. The aggregator `mbadolato/iTerm2-Color-Schemes` was used only to cross-check; it differs from upstream in places (e.g. Night Owl yellow `#ADDB67` vs upstream `#C5E478`; Everforest "Dark Hard" mixes dark and light accents), so it is not the source.

Our originals: **Reimagined Light/Dark** keep the bg/fg/caret/selection the app uses today (no visible change for existing users on Automatic) and add an original 16-color palette tuned to the app's blue accent. **Hacker** themes are a single-hue ramp on near-black — the name is generic; none of Termius' values are used.

## 8. Licensing and attribution plan

- All 15 bundled third-party themes are MIT (verified from each repo's `LICENSE` file on 2026-11-14; texts are the standard MIT grant). MIT requires the copyright notice and permission notice to be included "in all copies or substantial portions". Color values are arguably not copyrightable, but we include the notices anyway.
- Ship `Packages/CoreSSH/Sources/AppCore/Resources/terminal-themes-notices.txt`: for each credit, a header (project, source URL) and the upstream `LICENSE` text verbatim.
- `terminal-themes.json` carries a `credits` map; each theme points to its credit key (or null for originals).
- Settings → Terminal footer: "Theme credits…" button opens a sheet listing each project/author/license and the full notice text (read from the bundled file). The selected card's name tooltip names the author ("Dracula — by Dracula Theme, MIT").
- README gains a "Third-party themes" line pointing at the notices file.
- No Termius assets, names (other than our generic "Hacker"), screenshots or colors are copied. Our light/dark are original.

## 9. UI

### 9.1 Settings → Terminal

```
Terminal                                                     (22 pt semibold, like Connection)

Text Size                      [ − ]  13  [ + ]              (− disabled at 9, + disabled at 24)

Theme
┌──────────────────────────┐  ┌──────────────────────────┐
│ ▓▓ swatch ▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │  │ ▓▓ swatch ▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
│ Automatic                │  │ Reimagined Light         │
└──────────────────────────┘  └──────────────────────────┘
 …two flexible columns, 20 + 1 cards…

Applies to every open tab now. A host or group with its own theme keeps it.
Saved on this Mac only.                                     [Theme credits…]
```

- Card: rounded `Theme.cardBackground`, 2 pt `Theme.accent` border when selected (same as `CardRow`), `.isSelected` accessibility trait.
- Swatch (`ThemeSwatch`, ~64 pt tall): filled with the theme background; a foreground bar (60 % width) on top, then 5 short bars in ANSI red, green, yellow, blue, magenta (normal colors 1–5), and a 2 pt cursor block in the cursor color. Automatic's swatch is split diagonally: Reimagined Light / Reimagined Dark.
- Name below the swatch (13 pt), and a "Light"/"Dark" caption (11 pt secondary).
- Clicking a card sets `TerminalSettings.defaultThemeID` (nil for Automatic).

### 9.2 Host Details → Show more

- "Show more" becomes a working toggle ("Show more" / "Show less"); when open, a `DetailsCard` titled "Terminal" with a `Picker("Theme")` (menu style): first item **"Default (<resolved name>)"** — e.g. "Default (Nord — from group)" or "Default (Automatic)" — then a divider, then all catalog themes, each with a small 12 pt color dot of its background. Selecting sets `HostDetailsViewModel.themeID`; "Default" sets nil.
- Because a new host is saved immediately and edited in this same panel, the picker is available both "when creating" and "when editing".
- If the host's stored id is unknown to this build, the picker shows "Unknown theme (<id>)" as the selection and the host behaves as Default.

### 9.3 Group card context menu

`Theme ▸  ✓ Default · ─── · Reimagined Light · Reimagined Dark · …` — writes `HostGroup.defaultThemeID` via `HostsViewModel.setTheme(_:forGroup:)`.

## 10. Live update and resolution flow

1. `TerminalTabView.body` reads `@Environment(\.colorScheme)`, `terminalSettings.defaultThemeID`, `terminalSettings.fontSize`, `vault.revision` (via `vault.all(...)`) and `tab.savedHostID`, and computes `TerminalAppearance` with `TerminalThemeResolver`. Observation re-runs the body whenever any of these change — a Settings click, a Host Details edit, a group menu choice, or a sync merge from another Mac.
2. It passes the appearance to `SwiftTermView`; `updateNSView` calls `store.view(for:sessions:)` and then `view.apply(appearance)`.
3. `apply` compares with the last applied appearance; on change it installs colors (SwiftTerm redraws existing scrollback with the new palette — cells keep palette indices) and, if the size changed, sets the font, which triggers SwiftTerm's resize → `sizeChanged` → `SessionManager.resize` → remote PTY window-change.
4. Hidden tabs are not on screen; they receive the current appearance in `updateNSView` when selected, before drawing.
5. Text size change keeps the scrollback; the grid reflows to the new size the same way a window resize does today.

## 11. Open questions for Cory

1. **App default scope** — keep the default theme per Mac (recommended, like Connection settings), or sync it to every Mac (needs a new synced settings record)?
2. **Automatic** — OK to add an "Automatic" card (Reimagined Light in Light Mode, Reimagined Dark in Dark Mode) as the first card and initial default, so nothing changes until you pick? Or should the gallery hold only fixed themes, with Reimagined Dark as the default?
3. **Group picker** — is a "Theme" submenu on the group card's right-click menu enough for now, or do you want a Group Details panel (name, default identity, port, theme) in this milestone?
4. **Our theme names** — "Reimagined Light / Reimagined Dark", or something else ("Default Light/Dark", "Termius Reimagined …")?
5. **Text size** — range 9–24 pt, default 13, step 1 OK? Also add View-menu Cmd+= / Cmd+− / Cmd+0 for text size (applies the app-wide size)?
6. **Extra variants** — the same upstream licenses also cover Rosé Pine Moon and Rosé Pine Dawn (a light one), Kanagawa is complete, Everforest has Hard/Soft contrasts. Add Rosé Pine Moon/Dawn, or ship exactly the list?
7. **Upstream quirks** — keep upstream values exactly (Aura/Rosé Pine/Everforest bright = normal; Flexoki Light "white" = background), or allow small documented tweaks for readability?
