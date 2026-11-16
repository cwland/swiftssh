# SwiftSSH for iPhone and iPad: design

Date: 2026-11-15. Status: for Cory's approval (builder check done, questions answered).

## Intent

SwiftSSH 1.0 is a native macOS SSH client (Termius-inspired) that Cory uses daily on two Macs, with hosts, keys and snippets synced through his own end-to-end encrypted sync server. He wants a **quick-access companion for iPhone and iPad**: reach his servers from the couch or on the road, with **the same look and feel as the Mac app**, and still use **1Password**. Everything is set up on the Mac; the phone connects.

## Goals

- One universal app (iPhone and iPad), iOS/iPadOS 18 or later, in the same repository as the Mac app.
- Joins the existing sync server (same URL; an API key for the device) and shows the synced hosts, groups and snippets.
- Connects over SSH with the built-in engine, several sessions at once, each with its host's terminal theme.
- Looks like the Mac app: the navy chrome, host and group cards with OS badges, terminal themes.
- Works with 1Password within what iOS allows (see "1Password on iOS").
- Installed through TestFlight, built and uploaded by GitHub Actions.

## Non-goals

- Adding or editing hosts, groups, identities, keys or snippets (all done on the Mac).
- Split screen, workspaces, broadcast input, Focus mode.
- Shell History panel, Recently Deleted, Logs screen, custom highlighting editor.
- Port forwarding, SFTP, Mosh, jump hosts. (The project excluded these everywhere.)
- App Store release (TestFlight only for now).

## Anti-goals

- Never weaken the Mac app or its sync: a sync record written by iOS must never erase or corrupt Mac data. iOS writes as little as possible (see "Data").
- Never store a 1Password password in SwiftSSH on iOS.
- Never put a secret in a log, an error message or a crash report.
- No iOS-only fork of shared logic: shared behaviour lives in `CoreSSH`, tested once.

## Approaches considered

1. **New iOS app sharing the engine, with the Mac look moved into a shared style package (chosen, Claude's call after Cory left the "how" open).** The iOS app reuses `CoreModels`, `SyncCore`, `SSHCore` (Citadel engine) and the platform-neutral parts of `AppCore`. The look (colours, fonts, card and badge styles, terminal themes) moves from `App/Sources/UI/Theme.swift` and friends into a small shared SwiftUI package both apps use, so they can't drift. Screens are written fresh for iOS. Cost: a moderate one-time refactor of where the Mac styling lives; the Mac app's behaviour doesn't change.
2. **New iOS app copying the look.** Faster to start, no Mac change, but the two drift apart.
3. **Mac Catalyst / one set of views for both.** Rejected: the Mac app's terminal and window handling are AppKit-specific, and a shared-views rewrite risks the released 1.0 for a companion app.

## What the app does

### Layout
- **iPad:** in the spirit of the Termius iPad screenshot Cory shared: a sidebar (Hosts, Snippets, Known Hosts, Keys, Settings) with counts, a main area with Groups and Hosts card grids and a search field, and a tab bar of open sessions across the top (tap to switch, × to close). Hardware keyboard: ⌘W close session, ⌘1…9 switch session, ⌘F search hosts, ⌘K quick connect (filter hosts by name), ⌘[ / ⌘] previous/next session.
- **iPhone:** hosts screen (groups and hosts, search), tap to connect; a session screen; a floating pill to switch between open sessions or return to the host list.
- Light and dark appearance follow the system, like the Mac's default.

### Hosts
- Groups (nested; tap to open) and host cards with OS badge, label and subtitle, as on the Mac. Search by name or address.
- Tap a host to connect. Long-press: Connect, Copy Address, Show Details (read-only: address, port, user, how it signs in).

### Terminal
- SwiftTerm's iOS terminal view, the host's (or group's) theme, pinch to zoom the font, select/copy, paste.
- **Key bar** above the software keyboard: Esc, Tab, sticky **Ctrl** and **Alt** (tap = one keystroke, double-tap = lock, tap again = off; visibly highlighted), arrows, and `| / - ~ _`. Horizontally scrollable. Hidden when a hardware keyboard is attached.
- Startup snippet and tmux attach after login, as on the Mac (the shared session logic already does this).
- Connection screen like the Mac's (steps, then the log on failure, Close / Start Over).
- Host-key prompt for new or changed server keys; Known Hosts list (search, copy fingerprint).

### Snippets
- A drawer (sheet) in a session: search, tap to paste or run, `{{placeholder}}` values asked for first. Read-only list from sync.

### Connections on iOS
- iOS suspends apps in the background. Sessions are kept while the app is in the background briefly; when the app returns (or the network changes) each session is checked at once (the Mac's `checkConnection`) and dropped sessions reconnect automatically with the existing reconnect logic. Long background periods simply reconnect on return.
- Keep-alives as on the Mac while in the foreground.

### 1Password on iOS
iOS has no 1Password SSH agent and no `op` CLI. Cory chose:
- **Passwords:** the password prompt uses a secure text field marked as a password field with the host's username, so **iOS Password AutoFill** offers his 1Password login above the keyboard (tap + Face ID). Hosts whose password on the Mac is an `op://` reference show the prompt with a hint naming the 1Password item. Nothing is saved.
- **SSH keys: one-time import per key.** In 1Password iOS, Cory exports or shares the SSH Key item's private key to SwiftSSH (share sheet / Files, or paste). SwiftSSH stores it in the **device Keychain only** (this-device-only, not synced, not in iCloud Keychain), protected by Face ID / Touch ID / passcode when used. 1Password iOS can export SSH keys, including encrypted ones: SwiftSSH accepts OpenSSH (and PEM/PKCS#8) private keys, encrypted or not, and asks for the passphrase once at import (the stored copy is unencrypted inside the Keychain item).
- **Which key a host uses (Cory's choice: try imported keys).** On the Mac most 1Password hosts don't pin a key (`AgentKeyChoice(publicKey: nil)`: "the agent offers any key"). On iOS, a host or identity set to the 1Password agent offers the imported keys in turn: a key matching a pinned public key first (if the Mac pinned one), then the other imported Ed25519/ECDSA keys, stopping at the first the server accepts, never more than 5 attempts. No per-host setup.
- **Keys screen:** lists imported keys (name, type, fingerprint, the hosts pinned to it), import, delete. A 1Password host with no imported keys, or whose keys are all refused, shows a clear message with an "Import key" button.
- Keys kept in SwiftSSH's own vault on the Mac (not 1Password) arrive through sync and need no import.

### Settings and first launch
- First launch: join the sync server (URL + API key + vault passphrase as on the Mac's join flow), like the Mac welcome sheet. Nothing works before joining (no local editing exists).
- Settings: sync status and Sync Now, leave sync, Face ID app lock (on/off; locks after leaving the app), default terminal theme and text size, about/version.

### Data
- The full vault syncs down as on the Mac (same encrypted format, `LocalVault`, same persistence with a key in the iOS Keychain).
- Sync is last-writer-wins per record, so iOS must never rewrite an existing synced record from a possibly stale copy. On the Mac each connect rewrites the whole host record (`lastConnectedAt`, and the OS badge from detection) inside the shared `SessionManager`. **On iOS these host rewrites are switched off** (a `SessionManager` option, tested in the package; the Mac keeps today's behaviour). OS detection still runs for display only, not saved.
- iOS writes only **new** records: **known hosts** (trusting a server key; a changed key replaces only that known-host record, as on the Mac) and **connection logs** (append-only). Both go through the existing forward-compatible save.
- Imported 1Password keys are never written to the vault.

## Constraints

- Swift 6, iOS/iPadOS 18+, SwiftUI with UIKit where needed (terminal view, key bar input accessory).
- Same repo, XcodeGen; new app target in `App-iOS/` (or a second target in `App/project.yml`), same `App/Package.resolved` pins.
- `CoreSSH` already declares `.iOS(.v18)`. Mac-only code must be fenced with `#if os(macOS)`: `ProcessOnePasswordCLI`, the system-ssh engine (`SystemSSH/*`), and anything using `Process`, `NSWorkspace` or AppKit. The package tests must still pass on Linux and macOS.
- Bundle ID: `com.cwland.SwiftSSH` is the Mac app's. The iOS app uses its own ID (builder's choice, e.g. `com.cwland.SwiftSSH.mobile`); universal purchase is not needed.
- **RSA keys (Cory's choice: skip for now).** The built-in engine (Citadel) only signs with legacy `ssh-rsa` (SHA-1), which modern servers reject; on the Mac RSA-key hosts use system ssh, which iOS doesn't have. On iOS, RSA keys aren't offered and can't be imported; a host that needs one shows "RSA keys aren't supported on iPhone/iPad yet; use an Ed25519 key". `ConnectionPlanner` today routes RSA hosts and all agent hosts to system ssh: iOS needs its own routing (agent hosts → imported keys on the built-in engine; RSA → the message). RSA signing (`rsa-sha2-256/512`) is a possible later step.
- Signing and distribution: Cory's Apple Developer account (Team ID 7C54KH5NDL). TestFlight upload from GitHub Actions on the `xcode-27` runner using App Store Connect API key secrets. Cory creates the app record in App Store Connect and any new key or secret; Claude can't create tags or change repo settings, so Cory pushes tags.

## Decisions Cory made

- Quick-access companion, connect-only; no editing on iOS.
- Same look and feel as the Mac app; iPad and iPhone.
- No split screen/workspaces, no History, no Recently Deleted.
- 1Password: passwords through AutoFill; SSH keys imported once per key, kept on the device.
- Install via TestFlight.
- 1Password hosts without a pinned key: iOS tries the imported keys in turn.
- RSA keys: not supported on iOS for now.

## Left to the builder (Claude's calls, can be changed)

- Bundle ID, folder layout, the shared style package's name and exact contents.
- Background handling details (how long a session is kept; whether to request extra background time with `beginBackgroundTask`).
- Key bar exact key set beyond the list above, and sticky-modifier visuals.
- App icon: reuse the Mac icon artwork for iOS sizes.
- TestFlight workflow details (signing style, build numbers from the run number).

## Claude's calls from the builder check

- iOS doesn't rewrite synced host records (see Data); connection logs are kept (new records only).
- Encrypted 1Password key exports are accepted, passphrase asked once at import.

## Open questions

None.
