# Termius Reimagined — Design

Date: 2026-11-13
Status: Draft for review
Supersedes, where they conflict: `docs/SPEC.md` (the original spec). Notably, iCloud/CloudKit sync, SFTP, port forwarding, jump hosts and the dark-first palette are replaced or dropped below.

## 1. Intent and why

Cory uses Termius daily across several Macs to reach ~25 homelab and cloud hosts. He likes its look and workflow but doesn't want a subscription for features like syncing credentials between computers. Termius Reimagined is a personal, native macOS replacement that keeps the Termius look and the everyday SSH workflow, syncs through a server Cory runs himself in Docker, and adds an AI helper that writes shell commands for whatever OS the current session is connected to.

Success: Cory can uninstall Termius. Every Mac shows the same hosts, credentials, snippets and settings, and connecting to a box feels at least as quick as it does today.

## 2. Goals, non-goals, anti-goals

**Goals (version 1)**
- Termius-style hosts screen: card grid/list, OS badges, groups, tags, search/quick-connect bar, right-hand Host Details panel with Connect.
- Keychain of reusable credentials ("identities"): username plus password and/or SSH key, linked to many hosts or groups. Generate Ed25519 and RSA-4096 keys, import OpenSSH/PEM keys, copy a public key.
- SSH terminal sessions in tabs along a dark top bar, split panes, terminal themes and fonts, and a right-side drawer with Snippets and Shell History.
- Snippets: name + script, optional package (folder), paste or run.
- Known Hosts: trust-on-first-use fingerprint prompt, mismatch warning, a list you can review and delete from.
- Logs: connection history (date, start–end time, host, user, device), with a "saved" bookmark.
- AI command helper: describe a task in plain words, get a command for the connected OS, inserted at the prompt but not run.
- AI settings screen: provider, base URL, model, API key. Works with a local model (Ollama, LM Studio) or a cloud API.
- Command palette (Cmd+K): connect to a host, run a snippet.
- Self-hosted sync: one Docker container, each Mac points at it with a URL and an API key. Syncs hosts, groups, tags, identities and keys, snippets, known hosts, logs and AI settings.
- Optional app lock with Touch ID or the Mac password.

**Non-goals**
- SFTP browser, port forwarding, jump hosts, telnet, serial, Mosh.
- Teams, sharing, multi-user vaults ("Share this host" is dropped).
- iCloud/CloudKit sync and a paid Apple Developer account.
- The iOS/iPadOS app (the shared package keeps it possible, nothing more).
- Termius import (left to a later version; hosts get entered or imported from `~/.ssh/config`, see §11).

**Anti-goals: failure even if it technically works**
- The sync server, or anyone who gets into it, can read hostnames, usernames, passwords or keys.
- The AI helper runs a command without Cory pressing Enter.
- Day-to-day connecting is slower or clunkier than Termius.
- Losing the server means losing data: every Mac keeps a full local copy and works offline.

## 3. Constraints

- macOS 14+ (Sonoma and later). Swift 6 toolchain, SwiftUI with AppKit where needed.
- No paid Apple Developer account: the app runs as a locally signed build. No CloudKit and no iCloud Keychain.
- The development sandbox is Linux. It can build and test code that doesn't depend on Apple-only frameworks. SwiftUI, SwiftData, Security/Keychain and LocalAuthentication only run on Cory's Mac.
- The sandbox can commit to the repo but cannot `git push`; Cory pushes.
- The repo currently holds only `docs/SPEC.md`, `README.md` and `.gitignore`. No code exists, so milestone 1 starts from scratch and there's no local data to migrate.
- The server runs in Docker on Cory's homelab, reached over his LAN or VPN. TLS is expected to come from his existing reverse proxy; the server itself speaks HTTP.

## 4. Approaches considered

| | Approach | Trade-offs |
|---|---|---|
| **A (chosen)** | Swift sync server (Vapor + SQLite) sharing the `CoreSSH` package with the app | One language end to end; sync records, encryption and merge logic shared verbatim; all of it testable on Linux, so the test-first loop mostly runs without Cory. Costs: larger Docker image (~100 MB) and slower builds. |
| B | Go + SQLite server | Tiny image, fast builds. Costs: a second language and sync tests split across two codebases. |
| C | PocketBase (off-the-shelf backend) | Little server code, built-in admin UI. Costs: built around user logins rather than API keys, and ties the data format to PocketBase. |

Cory picked A. Because the server only ever stores encrypted records (§7), it stays small whatever language it's in; A wins on shared code and testability.

## 5. Architecture

One git repo, three parts:

```
termius-reimagined/
├── Packages/CoreSSH/          Swift package, builds on macOS and Linux
│   ├── Sources/CoreModels/    Plain Codable structs: Host, HostGroup, Identity, SSHKey,
│   │                          Snippet, KnownHost, ConnectionLog, AISettings, Tag;
│   │                          group-inheritance resolution; tag filtering; search
│   ├── Sources/SyncCore/      Record envelope, encryption (swift-crypto), key derivation,
│   │                          last-writer-wins merge, sync client (HTTP via AsyncHTTPClient
│   │                          or URLSession), server API types
│   ├── Sources/SSHCore/       Citadel wrapper: connect, auth (password, key), PTY shell,
│   │                          exec channel, host-key verification hook, OS detection
│   ├── Sources/AICore/        Prompt building from OS/shell context, OpenAI-compatible and
│   │                          Anthropic clients, response parsing
│   └── Tests/                 One test target per module
├── Server/                    Vapor app + Fluent/SQLite, depends on SyncCore
│   ├── Dockerfile, docker-compose.yml
│   └── Tests/
├── App/                       macOS app (SwiftUI), generated by XcodeGen from project.yml
│   ├── Sources/               Views, view models, SwiftData store, Keychain store,
│   │                          SwiftTerm bridge, app lock
│   └── Tests/
└── docs/
```

- **CoreModels** is the source of truth for data shapes. The app keeps them in SwiftData (`@Model` classes that map to and from the Codable structs); the server never sees them unencrypted.
- **SwiftData without CloudKit** means unique constraints and non-optional relationships are allowed. The CloudKit restrictions noted earlier no longer apply.
- **Secrets on the Mac** (passwords, private keys, key passphrases, the AI API key, the sync encryption key) live in the macOS Keychain as non-synchronizable items keyed by record UUID. SwiftData only stores a reference.
- **Libraries:** Citadel (SSH, on swift-nio-ssh), SwiftTerm (terminal emulator view), swift-crypto (AES-GCM, PBKDF2 via `_CryptoExtras`), Vapor + Fluent SQLite driver (server), XcodeGen (project file).

## 6. Data model

All records have `id: UUID`, `updatedAt` and `deleted` (tombstone) for sync.

- **HostGroup:** name, parent group (optional), and optional defaults for identity, port and terminal theme.
- **Host:** label, address, port (default 22), group, tags, username (optional), identity (optional), password/key set directly on the host (optional, for hosts that don't use an identity), OS badge (auto-detected, overridable), terminal theme override, startup snippet (optional), last connected date.
- **Inheritance (matches Termius):** a host that doesn't set a value checks its group, then the group's parents, one setting at a time. That applies to identity, port and theme. Changing a group default updates every host that inherits it.
- **Groups aren't folders:** viewing a group shows every host in it and its subgroups.
- **Tags:** shown under the host name, searchable. Choosing several tags shows hosts that have all of them. Removing a tag from a host doesn't delete the tag.
- **Identity:** label, username, and a password and/or a linked SSH key.
- **SSHKey:** label, type (ed25519, rsa), public key in OpenSSH format, private key (secret), passphrase (secret, optional).
- **Snippet:** name, script, package (optional folder name).
- **KnownHost:** host:port, key type, fingerprint (SHA256), first seen.
- **ConnectionLog:** host reference and label, username, device name, start time, end time, saved flag.
- **ShellHistoryEntry:** command text, host, time. Local and synced. Capped (e.g. last 1,000 entries).
- **AISettings:** provider (`openai-compatible` or `anthropic`), base URL, model, API key (secret).

## 7. Sync

**What the server stores.** One table of records:

```
id (UUID) | type | updated_at | deleted | device_id | seq (server-assigned, increasing) | ciphertext (blob)
```

Every field that says anything about Cory's hosts sits inside `ciphertext`. The server sees only IDs, a type name, timestamps and opaque bytes.

**Encryption.**
- A **sync passphrase** chosen by Cory the first time sync is set up.
- *Builder's call:* records are encrypted with a random 256-bit **vault key**, not with the passphrase directly. The vault key is wrapped (AES-256-GCM) by a key derived from the passphrase: PBKDF2-HMAC-SHA256(passphrase, salt, ≥600,000 iterations). Changing the passphrase later only re-wraps the vault key; no records are re-encrypted.
- Each record's JSON is sealed with AES-256-GCM using the vault key and a fresh random nonce, with `id`, `type`, `updated_at` (whole milliseconds), `deleted` and `device_id` as additional authenticated data, so the server can't swap a record under a different ID or alter the metadata it stores in the clear (re-date, delete, resurrect or re-attribute a record) without the client noticing.
- Vault metadata on the server: salt, iteration count and the wrapped vault key. A second Mac downloads it and asks for the passphrase. If unwrapping fails, the passphrase is wrong, and nothing syncs.
- The vault key is stored in each Mac's Keychain, so the passphrase is asked for once per Mac.
- Settings offers "Change sync passphrase", which re-wraps the vault key and updates the metadata.
- If the passphrase is lost, the synced data can't be decrypted. Each Mac's local copy still works.

**API (JSON over HTTP, `Authorization: Bearer <api key>`).**
- `GET /health`: no auth, for Docker health checks.
- `GET /v1/vault`: salt, KDF parameters, verifier. Returns 404 if not set up yet.
- `PUT /v1/vault`: create vault metadata. Fails if it already exists (no accidental overwrite).
- `POST /v1/vault/rewrap`: replace the wrapped vault key and salt when the passphrase changes. Requires the old wrapped key in the request, so it fails if another Mac changed it first.
- `GET /v1/records?since=<seq>&limit=<n>`: records changed after a server sequence number, in order, paged.
- `POST /v1/records`: batch upsert. For each record, the server keeps whichever copy has the newer `updated_at`, breaking ties by `device_id`. It returns the accepted records with their new `seq`.

**API keys.** Set through an environment variable (`SYNC_API_KEYS`, comma-separated) in docker-compose. Single vault, single user. Each Mac can get its own key so one can be revoked.

**Client behavior.**
- Sync runs at launch, on a timer (e.g. every 60 seconds) while the app is open, and shortly after a local change.
- Push local changes made since the last push, then pull everything after the last seen `seq`.
- Merge rule: newest `updatedAt` wins per whole record, ties broken by device ID. Deletes are tombstones, so they sync like edits. *Builder's call:* this is acceptable for a single user. Secrets live in their own records (Identity, SSHKey), so editing a host's label on one Mac can't clobber a password changed on another. Per-field merging is out of scope.
- **Joining an existing vault** (*builder's call*): the first Mac to set up sync creates the vault and uploads its data. When another Mac joins and already has local data, it asks once: **Merge** (upload local items, skipping hosts that match an existing one on address + port + username, and identities and keys that match on label + username or public key) or **Replace** (discard local data and use the vault's).
- Works fully offline. Sync status (last synced, errors) shows in the top bar's Vaults cloud icon.

**Server packaging.** A multi-stage Dockerfile (Swift build image → slim runtime image), a docker-compose file with a named volume for the SQLite file, port 8080, and the API-keys variable. Logs never contain request bodies.

## 8. App screens and behavior

Visual reference: Cory's screenshots of Termius desktop.

- **Window:** a dark navy top bar holding the traffic lights, a "Vaults" tab with a sync-status cloud icon, one tab per terminal session (OS badge + host label), a "+" button for a new tab, and a bell for notifications (sync errors, AI errors). The content area is light, with dark mode following macOS.
- **Sidebar:** Hosts, Keychain, Snippets, Known Hosts, Logs. Settings opens from the app menu (Cmd+,).
- **Hosts:** a search bar ("Find a host or ssh user@hostname…") with Connect, which connects to a saved host or to a typed `user@host[:port]`. Below that, "New host" (with a menu: New group, Import from ~/.ssh/config), a tag filter, grid/list toggle and the host cards. Single-click a card to open Host Details on the right; double-click to connect.
- **Host Details panel (right, slides over, not a modal):** Address with OS badge; General (label, parent group, tags); SSH port; Credentials (pick an identity, or type a username and password, or attach a key); "Show more" (startup snippet, terminal theme). Saves automatically, like Termius. A Connect button at the bottom. When several hosts share the same username and password, show the "N hosts reuse credentials — create an identity" hint.
- **Keychain:** cards for identities and keys. New identity, new key (generate Ed25519 or RSA-4096, or import from a file or paste), copy a public key, and show which hosts use each.
- **Snippets:** cards (name and first line of script), New snippet, packages as filters, and a Shell History panel on the right.
- **Known Hosts:** fingerprint cards, search, delete.
- **Logs:** a table of date, time range, user/device, host and a saved bookmark, sorted newest first.
- **Terminal tab:**
  - SwiftTerm view, xterm-256color, copy-on-select (setting), paste, URL click, OSC 52 clipboard.
  - Split the current pane horizontally or vertically; each pane is its own session; Cmd+W closes the focused pane.
  - Right drawer (toggle) with three sections: Snippets (click to paste, double-click or Run to execute, "Run in all tabs"), Shell History, and Theme & Font.
  - When the connection drops: keep the scrollback, show a banner with Reconnect.
- **Command palette (Cmd+K):** fuzzy search over hosts (connect), snippets (run in the current pane) and screens.
- **App lock (setting, off by default):** Touch ID or the Mac password on launch and after a chosen idle time, before any secret is read.
- **Settings:** Sync (server URL, API key, passphrase setup or unlock, status, "Sync now"), AI (provider, base URL, model, API key, "Test connection"), Terminal (default theme, font, copy-on-select), Security (app lock).

## 9. SSH behavior

- Auth methods: password, private key (with optional passphrase), keyboard-interactive (answers prompts using the stored password or asks Cory).
- **Host keys:** on first connect, show the fingerprint and ask to trust it. Trusted keys are saved as KnownHost records. If a key changes, block the connection with a clear warning and offer "Remove old key and trust new one".
- **OS detection:** after the first successful connect, run a short exec command (`uname -s` and `cat /etc/os-release`) and map the result to a badge (Ubuntu, Debian, Raspberry Pi OS, Fedora, CentOS/RHEL, Alpine, Arch, macOS, FreeBSD, generic Linux, Synology DSM, Home Assistant OS). Store the result. The badge can be changed by hand.
- **Startup snippet:** runs after the shell opens, if set.
- Each session writes a ConnectionLog when it opens and updates the end time when it closes.

## 10. AI command helper

- Open with Cmd+I or a toolbar button in a terminal tab. A small panel appears above the prompt with a text field.
- Context sent: OS name and version, and shell (from detection), plus Cory's request. Never sent: scrollback, history, hostnames or credentials.
- The model is asked for exactly one command and a one-line explanation, in a fixed format the app parses.
- The panel shows the command and explanation with Insert (default, Enter) and Copy. Insert types the command at the prompt **without a newline**, so nothing runs until Cory presses Enter in the terminal.
- Commands that look destructive (`rm -rf`, `mkfs`, `dd`, `shutdown`/`reboot`, `chmod -R` on `/`, etc.) show a warning label.
- **Providers:**
  - *OpenAI-compatible* (`/v1/chat/completions`): covers Ollama, LM Studio, vLLM, OpenRouter and OpenAI.
  - *Anthropic* (`/v1/messages`).
- The settings sync like everything else; the API key travels encrypted.

## 11. Testing and delivery

**Testing (test-first throughout).**
- `CoreModels`, `SyncCore`, `AICore` and `Server`: unit tests run on Linux in the dev sandbox with `swift test`. Server tests use Vapor's in-process testing and an in-memory SQLite database. The sync client is tested against the real server in-process.
- `SSHCore`: unit tests for OS detection parsing and host-key decisions on Linux; an integration test against a throwaway OpenSSH server in a container, if the sandbox can run one.
- App: unit tests for view models, the SwiftData mapping and the Keychain store run on Cory's Mac (`xcodebuild test`), with Cory pasting back failures. UI is checked by hand against the screenshots.

**Delivery order (each a working milestone):**
1. `CoreModels` + `SyncCore` + Server, with Docker image. Testable end to end on Linux.
2. App shell: window, top bar, sidebar, Hosts / Host Details / groups / tags / Keychain, all local.
3. SSH terminal: connect, tabs, host-key prompts, OS detection, logs.
4. Sync in the app: settings, passphrase setup and unlock, background sync.
5. Snippets, shell history, terminal drawer, themes and fonts, Known Hosts screen.
6. Split panes, command palette, app lock, `~/.ssh/config` import.
7. AI helper and AI settings.

## 12. Left to the builder

- Exact SwiftUI layout values, colors and spacing, matched to the screenshots.
- Which terminal themes ship beyond a Termius-like light and dark default (Dracula, Solarized, Nord and Monokai are good candidates).
- How shell history is captured (recommended: record lines sent with Enter from the app, plus snippet and AI insertions; shell-integration hooks are out of scope).
- Sync timer and debounce values, and page sizes.
- How `~/.ssh/config` import maps `Host` blocks (HostName, User, Port, IdentityFile) to hosts and keys.
