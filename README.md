# SwiftSSH

**A native macOS SSH client with the look and workflow of Termius, without the subscription.**

SwiftSSH keeps your servers, logins and SSH keys in one encrypted vault, opens them in fast terminal tabs and split-screen workspaces, and keeps every Mac in step through a small sync server you run yourself. It works with 1Password for SSH keys and passwords, so secrets can stay in 1Password instead of the app.

- **Platform:** macOS 15 or later (Apple silicon and Intel), Swift 6, SwiftUI with AppKit
- **Download:** signed and notarized `.dmg` on the [Releases](https://github.com/cwland/swiftssh/releases) page
- **Formerly** "Termius Reimagined", renamed to SwiftSSH in v0.11.0. On first launch SwiftSSH moves an existing Termius Reimagined vault over by itself (see [App/README.md](App/README.md#moving-over-from-termius-reimagined-first-launch)).

SwiftSSH is SSH only, on purpose: no SFTP browser, port forwarding, jump hosts, Telnet, serial or AI features.

---

## What it does

### Hosts
- **Host cards** with an operating-system badge that is detected on first connect (Ubuntu, Debian, Synology, macOS, Proxmox and many more; Settings → OS Icons lets you pick or upload your own).
- **Nested groups** with their own panel: name, parent group, terminal theme, tmux session and a startup snippet that every host in the group inherits.
- **Host Details** panel: address, port, username, and either a direct login (password, SSH key or 1Password key) or a shared **identity**. Switching between the two keeps both; only the chosen one is used.
- Click to select, double-click to connect, pencil (or E) to edit. Right-click for Connect in a New Window, Open in Workspace, Add to Workspace, Move to, Duplicate and Remove; these work on several selected hosts at once.
- **Search**, multi-select, and an "Open N in Workspace" button for the selected hosts.
- **Recently Deleted** (Settings) for hosts, groups and snippets: restore with everything, on every Mac, or delete permanently.

### Keychain
- **Identities** (a username with a password or key, shared by many hosts) and **SSH keys**.
- Generate Ed25519 or RSA keys, import existing OpenSSH keys, and install a key's public half on a server from the app.

### Terminal
- Fast xterm-256color terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) in **tabs** of equal width that drag to reorder, and in several windows (Duplicate in New Window).
- **Themes:** a gallery with Automatic, SwiftSSH Light/Dark and 18 bundled themes. Hosts, groups and even single workspace panes can have their own theme; open tabs change live. Text size with ⌘= / ⌘− / ⌘0.
- **Highlighting:** errors, warnings and IP addresses coloured by default, plus your own rules (Settings → Highlighting): a word, phrase or regular expression with a colour, bold and match-case, synced to every Mac, with a live preview.
- Clickable links, safe multi-line paste (bracketed paste, or a warning when the shell can't do it).
- **tmux:** a host or group can attach to (or create) a named tmux session on connect.
- **Startup snippets:** a command typed after login, per host or inherited from its group.

### Connections
- **Connection screen** in the style of Termius: each step of the connection as it happens, and on failure the full log with Close, Edit Host and Start Over.
- **Host key checks** on every connection, with a clear prompt for a new or changed server key, and a **Known Hosts** screen to search, copy fingerprints and remove trusted keys.
- **Fast disconnect detection:** keep-alives every 5 seconds, plus an immediate check when typing gets no echo, when the network changes and after sleep.
- **Automatic reconnect** with a countdown popup (for reboots and dropped networks) for about three minutes; typing `exit` simply closes the tab.
- Two SSH engines, picked per connection: a built-in one ([Citadel](https://github.com/orlandos-nl/Citadel), bundled with a small patch) and the Mac's own `ssh` for 1Password agent keys and RSA keys.

### Workspaces (split view)
- Drag a tab onto a terminal to split it (a green box shows where it will land), or use Split Right / Split Down. Up to 16 panes, in any direction.
- **Focus mode** (⌘⇧M): one large pane with the others in a list; drag rows to swap panes.
- **Broadcast input** (⌘B): type into every pane at once, with per-pane opt-out.
- **Saved workspaces** (⌘S): layout, hosts and pane themes, shown as tiles on the Hosts screen. Closing asks to save unsaved changes (can be turned off).

### Snippets
- Saved commands and scripts in **groups**, with `{{placeholder}}` and `{{name:default}}` values asked for when run.
- **Snippets panel** in any terminal (⌘.): Paste, Run, Run in All Tabs or All Panes.
- **Run on hosts**: pick hosts and run a snippet on each.
- **Snippet library:** about 70 ready-made admin commands (system, disk, processes, network, services, logs, Docker, packages, users and security, files). Tick the ones you want and they become ordinary snippets.

### Shell history
- **History panel** (⌘Y) reads the server's own bash, zsh or fish history over the connection: newest first, searchable, with Paste, Run, Copy and Save as Snippet. It is never stored or synced, and passwords typed at prompts can't end up in it.

### 1Password
- **SSH keys from 1Password's SSH agent**, including keys in other vaults. SwiftSSH can write 1Password's `agent.toml` for you, keeping your existing rules and a backup.
- **Passwords as `op://` references**: pick a field from 1Password ("Pick from 1Password") and the secret is read at connect time, never stored in SwiftSSH.
- **Setup checklist** (Settings → 1Password) that tells apart every common problem (CLI not installed, CLI integration off, macOS privacy block, 1Password locked, agent offering no keys) with a one-click fix for each.
- **Touch ID focus:** when 1Password shows its approval prompt, SwiftSSH hands it the keyboard focus and takes it back afterwards.

### Sync between Macs
- **End-to-end encrypted** sync of hosts, groups, identities, keys, snippets, known hosts and highlighting rules to a server you run yourself (one small Docker container). The server only ever sees encrypted records.
- Each Mac signs in with its own API key; the vault passphrase can be changed; a joining Mac can merge its local data instead of replacing it; the newest edit wins.
- Forward-compatible: an older app never erases settings written by a newer one.
- Self-hosting guide: [Server/README.md](Server/README.md).

### First launch and privacy
- A **welcome sheet** on a new Mac: join your sync server, set up 1Password, done (Help → Set Up SwiftSSH… reopens it).
- Everything is stored in one encrypted file on your Mac, keyed by a single Keychain item. Passwords and keys never appear in logs, errors or command lines.
- **Connection logs** (sidebar → Logs) record when and where you connected, not what you typed.

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Reconnect the selected tab |
| ⌘. | Show or hide the Snippets panel |
| ⌘Y | Show or hide the History panel |
| ⌘W | Close the tab, pane or Settings window |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌘B | Broadcast input in a workspace |
| ⌘⇧M | Focus mode / split view |
| ⌘S | Save the workspace |
| ⌘= / ⌘− / ⌘0 | Text size |
| E | Edit the selected host |

---

## Install

Download the latest `SwiftSSH-x.y.z.dmg` from [Releases](https://github.com/cwland/swiftssh/releases), open it and drag SwiftSSH to Applications. Builds are signed with Developer ID and notarized by Apple, so they open without warnings and keep their Keychain and 1Password permissions across updates.

## Build from source

The Xcode project is generated from `App/project.yml` with XcodeGen (it isn't committed). Xcode 27 or later.

```
brew install xcodegen
cd App && xcodegen generate
xcodebuild -project SwiftSSH.xcodeproj -scheme SwiftSSH -destination 'platform=macOS' test
open SwiftSSH.xcodeproj   # then Run (Cmd+R)
```

Local builds use a self-signed certificate so macOS permissions survive rebuilds; see [App/README.md](App/README.md). Package tests run on macOS or Linux: `cd Packages/CoreSSH && swift test`.

## Releases

Pushing a tag `vX.Y.Z` (matching `MARKETING_VERSION` in `App/project.yml`) builds, signs, notarizes and publishes a GitHub Release with the `.dmg` (`.github/workflows/release.yml`). A `build-*` tag builds the `.dmg` as a downloadable artifact without a release. Package versions are pinned in `App/Package.resolved`.

## Repository layout

| Path | What's there |
|---|---|
| `App/` | The macOS app (SwiftUI/AppKit), its tests and XcodeGen project |
| `Packages/CoreSSH/` | Shared Swift package: models (`CoreModels`), SSH engines (`SSHCore`), encrypted sync (`SyncCore`) and app logic (`AppCore`), ready for a future iOS app |
| `Packages/Citadel/` | Bundled SSH library with a small patch (`PATCHES.md`) |
| `Server/` | The sync server (Swift, Vapor, SQLite) and its Docker setup |
| `docs/` | The original specification and design notes |

## Credits

Terminal emulation by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm); SSH by [Citadel](https://github.com/orlandos-nl/Citadel) and [swift-nio-ssh](https://github.com/apple/swift-nio-ssh). Bundled terminal themes are MIT-licensed by their authors: see `Packages/CoreSSH/Sources/AppCore/Resources/terminal-themes-notices.txt` (also in Settings → Terminal → Theme credits). Inspired by [Termius](https://termius.com); not affiliated with it.
