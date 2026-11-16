# SwiftSSH for iPhone and iPad: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A universal iOS/iPadOS 18 app, "SwiftSSH", that joins Cory's sync server and connects to his synced hosts with the Mac app's look, as a connect-only companion.

**Architecture:** New XcodeGen app in `App-iOS/` using the existing `CoreSSH` package (CoreModels, SyncCore, SSHCore with the Citadel engine, AppCore) and a new shared SwiftUI style package `Packages/SwiftSSHUI` that the Mac app also adopts. iOS-specific behaviour (no host-record rewrites, imported-key auth, no RSA, no system ssh) is expressed as options and routing in `AppCore`, tested in the package. A CI workflow builds the iOS app on every push to the `ios` branch; TestFlight upload runs on `ios-v*` tags.

**Tech Stack:** Swift 6, SwiftUI + UIKit (iOS), SwiftTerm (iOS `TerminalView`), Citadel/swift-nio-ssh, XcodeGen, GitHub Actions (`xcode-27` runner), App Store Connect API.

**Spec:** `docs/superpowers/specs/2026-11-15-ios-companion-design.md`

## Global Constraints

- iOS/iPadOS 18.0 minimum; macOS app unchanged at 15.0 minimum. Swift 6 strict concurrency.
- Same repo, branch `ios`. Package versions pinned by `App/Package.resolved` (copy it for the iOS project too).
- iOS bundle ID `com.cwland.SwiftSSH.mobile`, display name "SwiftSSH", version 1.0.0, build number = CI run number. Team ID 7C54KH5NDL.
- The Mac app's behaviour must not change (its tests and the release workflow must still pass).
- iOS never rewrites an existing synced record; it only creates KnownHost and ConnectionLog records.
- Imported keys live only in the iOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronizable); never in the vault, logs, errors.
- RSA keys are not usable on iOS: not importable, and RSA-key hosts show "RSA keys aren't supported on iPhone/iPad yet; use an Ed25519 key."
- At most 5 key attempts per connection.
- Package tests run on Linux (`swift test -Xlinker --allow-shlib-undefined --skip SSHCoreTests`); `@MainActor` XCTest methods must be `async` there. New logic goes in AppCore with tests; app layers stay thin.
- Commit messages end with the session's Co-Authored-By / Claude-Session lines.

## Review Focus

1. **Stale-copy writes:** connecting on iOS must not save the host (`lastConnectedAt`, OS badge) — test that the host's stored record is byte-identical after a connect.
2. **Encrypted 1Password key exports:** an encrypted OpenSSH Ed25519 key with the right passphrase imports; a wrong passphrase gives a clear error, nothing stored.
3. **Sticky Ctrl with the software keyboard:** Ctrl then `c` sends 0x03 once and releases; double-tap locks until tapped again; a hardware keyboard's own Ctrl is unaffected.
4. **App returning from background** with a dead connection: the session is checked at once and reconnects; no duplicate sessions.
5. **Host whose 1Password key isn't imported / all keys refused:** a clear message with "Import key", no crash, no endless retry.

---

### Task 1: CoreSSH builds for iOS, plus the iOS CI check

**Files:** `Packages/CoreSSH/Sources/AppCore/OnePassword/ProcessOnePasswordCLI.swift`, `Packages/CoreSSH/Sources/SSHCore/SystemSSH/*`, any other file using `Process`, `NSWorkspace`, AppKit or Mac-only APIs; `.github/workflows/ios.yml` (new).

**Interfaces:**
- Produces: CoreSSH compiles for `generic/platform=iOS` and `iOS Simulator`; Mac-only types exist only under `#if os(macOS)`. Shared code that referenced them (e.g. `SessionManager`'s `opClient`, system-ssh factory) still compiles on iOS (fence call sites or use protocol types that exist on both).
- Workflow `ios.yml`: on push to branch `ios` (and `workflow_dispatch`), runs on `xcode-27`, selects latest-stable Xcode, builds the CoreSSH package for iOS Simulator (`xcodebuild -scheme CoreSSH-Package -destination 'generic/platform=iOS Simulator' build`), and — once `App-iOS/project.yml` exists — `xcodegen` + builds the iOS app for the simulator with `CODE_SIGNING_ALLOWED=NO`, uploading the build log on failure. Uses `pipefail` (`defaults.run.shell: bash`).

- [ ] Step 1: Fence Mac-only code; keep Linux/macOS package tests green.
- [ ] Step 2: Add `ios.yml`; push; read the run result with `gh run list/view --repo cwland/swiftssh` and fix until the CoreSSH iOS build is green.
- [ ] Step 3: Commit.

### Task 2: SessionManager never rewrites hosts on iOS

**Files:** `Packages/CoreSSH/Sources/AppCore/Sessions/SessionManager.swift`; tests in `Tests/AppCoreTests/SessionManagerTests.swift` (or a new file).

**Interfaces:** Produces `SessionManager.init(..., recordsHostUpdates: Bool = true)`. When false: no `lastConnectedAt` save, OS detection result kept in memory only (exposed so the UI can show the badge: `func detectedBadge(hostID: UUID) -> OSBadge?`), ConnectionLog still saved.

- [ ] Step 1: Failing test `testConnectingWithoutHostUpdatesLeavesTheHostRecordUnchanged` — connect a fake session to a saved host with `recordsHostUpdates: false`, finish OS detection; assert the stored host record payload and `updatedAt` are unchanged and a `ConnectionLog` exists; and `detectedBadge` returns the probed badge.
- [ ] Step 2: Implement; existing tests (default `true`) unchanged.
- [ ] Step 3: Commit.

### Task 3: Key-candidate auth and iOS connection routing

**Files:** `Packages/CoreSSH/Sources/SSHCore/TerminalSession.swift`, `CitadelSession.swift`; `Packages/CoreSSH/Sources/AppCore/Domain/ConnectionPlanner.swift`; tests.

**Interfaces:**
- SSHCore: `public struct SSHKeyCandidate: Sendable { public let type: KeyType; public let pem: String; public let label: String }` and `SSHCredential.privateKeys([SSHKeyCandidate])`; `CitadelSession` offers them in order (Ed25519/ECDSA only), stops at the first accepted, at most 5; `description` never prints key material. Authentication failure with all candidates refused → existing auth-failure error.
- AppCore: `public enum ConnectionPlatform { case mac, ios }`; `ConnectionPlanner.plan(hostID:vault:platform:importedKeys:)` where `importedKeys: [SSHKeyCandidate]` with their public keys; for `.ios`: engine always `.citadel`; a host/identity using a 1Password agent key → `.privateKeys` ordered pinned-public-key match first, then the rest (max 5); none imported → throws `ConnectionPlanError.noImportedKeys(hostLabel:)`; a resolved RSA private key → throws `.rsaUnsupported(hostLabel:)`. `.mac` behaviour unchanged (existing signature forwards with `.mac`).
- To match pins, candidates carry `publicKey: String` ("type base64"); add it to `SSHKeyCandidate` (not printed).

- [ ] Step 1: Failing planner tests: pinned-first ordering; unpinned uses all (≤5); no imported keys → `.noImportedKeys`; RSA → `.rsaUnsupported`; `useSystemSSH` ignored on iOS; Mac plans unchanged.
- [ ] Step 2: Implement planner; implement Citadel multi-key offer (SSHCore tests where the in-process test server allows: accepted second key; all refused → auth failure).
- [ ] Step 3: Commit.

### Task 4: Imported key library

**Files:** `Packages/CoreSSH/Sources/AppCore/SSHKeys/ImportedKeyLibrary.swift` (new), `SSHKeyImporter.swift` (encrypted OpenSSH support if missing); tests.

**Interfaces:**
- `public struct ImportedKeyInfo: Codable, Sendable, Identifiable { id: UUID; name: String; type: KeyType; publicKey: String; fingerprint: String; importedAt: Date }`
- `public protocol ImportedKeyStorage: Sendable { func list() throws -> [ImportedKeyInfo]; func save(_ info: ImportedKeyInfo, privateKey: String) throws; func privateKey(id: UUID) throws -> String; func delete(id: UUID) throws }` (iOS app implements with Keychain; tests with an in-memory one).
- `@MainActor @Observable public final class ImportedKeyLibrary { init(storage:); var keys: [ImportedKeyInfo]; func importKey(text: String, name: String?, passphrase: String?) throws -> ImportedKeyInfo; func delete(_ id: UUID) throws; func candidates() throws -> [SSHKeyCandidate]; func hosts(using key: ImportedKeyInfo, vault: LocalVault) -> [SavedHost] }`
- Errors: `.needsPassphrase`, `.wrongPassphrase`, `.rsaNotSupported`, `.notAPrivateKey`, `.duplicate(existingName)`.
- Stored private key is the unencrypted OpenSSH form (the Keychain item is the protection).

- [ ] Step 1: Failing tests: unencrypted Ed25519 imports (name defaults to the key comment, fingerprint SHA256); encrypted OpenSSH Ed25519 (bcrypt KDF, aes256-ctr) with passphrase imports, without → `.needsPassphrase`, wrong → `.wrongPassphrase`; RSA → `.rsaNotSupported`; duplicate public key → `.duplicate`; `candidates()` returns all keys with public keys. Generate fixtures with `ssh-keygen -t ed25519 -N pass` in the test or commit fixture text.
- [ ] Step 2: Implement (bcrypt_pbkdf + AES-256-CTR via swift-crypto `_CryptoExtras` if `SSHKeyImporter` can't decrypt today). If encrypted import proves infeasible, record a ruling and show "Export the key without a passphrase" instead — but try first.
- [ ] Step 3: Commit.

### Task 5: Shared style package `SwiftSSHUI`, adopted by the Mac app

**Files:** `Packages/SwiftSSHUI/` (new SwiftPM package, macOS 15 + iOS 18, depends on CoreSSH `AppCore`/`CoreModels` for badge and theme data); `App/Sources/UI/Theme.swift` and the Mac views using `CardRow`, `SymbolBadge`, OS badge views, terminal-theme colour conversion; `App/project.yml` (add the package).

**Interfaces:** Produces public `SwiftSSHTheme` (the token values from `Theme.swift`, with cross-platform dynamic colours via `UIColor`/`NSColor`), `CardRow`, `SymbolBadge`, the OS badge view used on host cards, group card, and `TerminalTheme` → platform colour helpers. The Mac `Theme` becomes a thin alias/forwarder so call sites barely change. No visual change on the Mac.

- [ ] Step 1: Move code; Mac app compiles (`swiftc -parse` + the `ios.yml`-style Mac compile is done by the release workflow later; also build SwiftSSHUI for iOS in `ios.yml`).
- [ ] Step 2: Commit.

### Task 6: iOS app shell, vault, sync join, Face ID lock

**Files:** `App-iOS/project.yml`, `App-iOS/Sources/...`, `App-iOS/Resources` (Assets with the Mac icon artwork for iOS sizes), Info.plist keys (`NSFaceIDUsageDescription`, local network usage), `App-iOS/Package.resolved` copy step in CI.

**Interfaces:** `IOSEnvironment` (`@MainActor @Observable`): opens the vault (`EncryptedFileVaultPersistence` in Application Support, key from an iOS Keychain provider, this-device-only), creates `KnownHostsStore`, `SessionManager(recordsHostUpdates: false, makeSession: CitadelSession…)`, `SyncCoordinator`, `ImportedKeyLibrary(storage: KeychainImportedKeyStorage)`. State: needs join → joined. Join screen reuses `SyncCoordinator`'s join API (URL, API key, vault passphrase; join-only, no local data so no merge). App lock: setting `appLockEnabled` (UserDefaults), `LocalAuthentication` on launch and on return after > 30 s in background, a cover view while locked and in the app switcher snapshot.

- [ ] Step 1: Scaffold, environment, join flow, lock; CI iOS build green.
- [ ] Step 2: Commit.

### Task 7: Hosts screens (iPad sidebar + grid, iPhone list)

**Interfaces:** `RootView` switches on `horizontalSizeClass`: regular → `NavigationSplitView` (sidebar: Hosts, Snippets, Known Hosts, Keys, Settings with counts from `SidebarCounts`-style logic) + session tab bar across the top; compact → `NavigationStack` + floating session pill. Hosts screen: groups (tap to drill in, breadcrumb/back), host cards (shared `CardRow` + OS badge), search (label, address), long-press menu (Connect, Copy Address, Show Details read-only sheet). Hardware shortcuts ⌘F (search), ⌘K (quick-connect filter sheet).

- [ ] Step 1: Build; commit.

### Task 8: Sessions and terminal

**Interfaces:**
- AppCore `KeyBarState` (tested): sticky modifiers `ctrl`/`alt` with states off/once/locked (tap: off→once, once→off; double-tap within 0.35 s: →locked; tap while locked→off); `func transform(_ input: [UInt8]) -> [UInt8]` applies Ctrl (letters/`@[\]^_` → control codes) and Alt (ESC prefix) then clears `once` states; key actions Esc, Tab, arrows (honour application cursor mode passed in), symbols.
- iOS `TerminalContainerView` (UIViewRepresentable around SwiftTerm `TerminalView`, wired to `SessionManager` output/input like the Mac `SwiftTermView`), theme from the host, pinch to zoom (font size persisted per device), copy/paste via SwiftTerm's menu, custom `inputAccessoryView` = KeyBar (hidden when `GCKeyboard.coalesced != nil`).
- Session UI: connection screen (steps + log on failure, Close / Start Over — port the Mac `ConnectionScreen` look), host-key prompt sheet, password prompt sheet with `.textContentType(.username)` / `.password` fields so 1Password AutoFill offers logins (and a hint naming the 1Password item for `op://` hosts), errors for `.noImportedKeys` / `.rsaUnsupported` with "Import key" opening the Keys screen.
- iPad: session tab bar (tap to switch, × to close), ⌘W, ⌘1…9, ⌘[ / ⌘]. iPhone: floating pill showing open sessions + "Hosts".

- [ ] Step 1: `KeyBarState` tests first, then implement; build UI; commit.

### Task 9: Snippets drawer, Known Hosts, Keys, Settings

**Interfaces:** Snippets drawer sheet in a session (search, groups, tap Paste / Run; placeholders via a form using `SnippetTemplate`). Known Hosts list (reuse `KnownHostsViewModel` read parts; Copy Fingerprint; no remove — removal rewrites synced state, so omit on iOS). Keys screen: list `ImportedKeyLibrary.keys` (name, type, fingerprint, hosts pinned to it), Import via paste field, Files picker (`.fileImporter` for any file type), and "Open in SwiftSSH" (register as a handler for files with `.key`/`.pem`/no extension via `UTImportedTypeDeclarations` + `onOpenURL`), passphrase prompt, delete with confirmation. Settings: sync status + Sync Now + Leave sync (confirm; deletes local vault and keys), app lock toggle, default theme and text size, About (version).

- [ ] Step 1: Build; commit.

### Task 10: Foreground/background lifecycle

**Interfaces:** On `scenePhase` → `.background`: `beginBackgroundTask` to finish in-flight work; record the time. On `.active`: `sessions.checkConnections()` (existing), and reconnect dropped sessions via existing auto-reconnect; on network change (`NWPathMonitor`, as the Mac `ConnectionWatcher`) the same. No duplicate sessions.

- [ ] Step 1: Implement; commit.

### Task 11: TestFlight workflow and docs

**Files:** `.github/workflows/ios-release.yml` (new), `App-iOS/README.md`, top-level README section.

**Interfaces:** On tag `ios-v*` (version must match `MARKETING_VERSION` in `App-iOS/project.yml`): archive with automatic signing using the App Store Connect API key (`-allowProvisioningUpdates -authenticationKeyPath/-ID/-IssuerID`), export `app-store-connect` IPA, upload with `xcrun altool --upload-app` (or `notarytool`'s sibling `xcrun iTMSTransporter`), build number = run number. Secrets reused: `NOTARY_KEY_P8/ID/ISSUER_ID` (the key may need the App Manager role for uploads — document it), `APPLE_TEAM_ID`. Document Cory's one-time steps: create the app record "SwiftSSH" with bundle ID `com.cwland.SwiftSSH.mobile` in App Store Connect, register the bundle ID, raise the key role if needed, add himself as an internal TestFlight tester, push the tag.

- [ ] Step 1: Write workflow + docs; commit.
