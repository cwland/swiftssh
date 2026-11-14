# Milestone 3: SSH Terminal (Citadel + system ssh) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect to saved hosts and quick-connect targets in terminal tabs, with trust-on-first-use host keys, password and key logins, OS detection and a connection log — using Citadel by default and the Mac's `/usr/bin/ssh` when a host uses an RSA key or opts in.

**Architecture:** A new `SSHCore` library in `Packages/CoreSSH` defines one `TerminalSession` abstraction with two engines: `CitadelSession` (pure Swift SSH) and `SystemSSHSession` (`/usr/bin/ssh` in a pseudo-terminal). `AppCore` gains connection planning, a known-hosts trust store, OS detection and a `SessionManager` that drives sessions as state machines. The app shows sessions as tabs using SwiftTerm's `TerminalView`. Both engines are integration-tested on Linux against a real local `sshd`.

**Tech Stack:** Swift 6, Citadel 0.9.x (SwiftNIO SSH), SwiftTerm, OpenSSH client tools, SwiftUI/AppKit (macOS 15+).

**Spec:** `docs/superpowers/specs/2026-11-13-termius-reimagined-design.md` §8 (Terminal tab), §9 (SSH behavior), §11 milestone 3. **Design change approved by Cory (2026-11-13):** two engines ("do both") and a macOS 15 minimum.

## Spike findings (Linux, OpenSSH 9.6 server, Citadel 0.9.2)

- Citadel: password login, Ed25519 key login (`Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`), `executeCommand`, `withPTY` all work. RSA key login fails (`allAuthenticationOptionsFailed`) — Citadel signs only with legacy `ssh-rsa` (SHA-1).
- `withPTY` and `withTTY` are `@available(macOS 15.0, *)`.
- When the server ends the shell, `withPTY` throws `Already closed` from its own channel close — treat as a normal end of session.
- `executeCommand` throws if the command writes to stderr unless `mergeStreams: true` is passed.
- `SSHHostKeyValidator.custom(_:)` takes a `NIOSSHClientServerAuthenticationDelegate`, which receives the server's `NIOSSHPublicKey`.

## Global Constraints

- Deployment targets: `Packages/CoreSSH` platforms `.macOS(.v15), .iOS(.v18)`; app `MACOSX_DEPLOYMENT_TARGET: "15.0"`.
- Dependencies: `https://github.com/orlandos-nl/Citadel.git` `.upToNextMinor(from: "0.9.2")`; `https://github.com/migueldeicaza/SwiftTerm.git` latest release at implementation time (record the version in the commit). `SSHCore` depends on Citadel; only the app depends on SwiftTerm.
- `AppCore` still builds and tests on Linux; `SSHCore` builds on Linux too. Linux test command: `swift test -Xlinker --allow-shlib-undefined` (sandbox-only flag, never in Package.swift).
- Engine choice: `systemSSH` when the effective credential is an RSA key, or the host's `useSystemSSH == true`; otherwise `citadel`. Quick connect without a saved host uses `citadel`.
- Terminal type `xterm-256color`. Initial PTY size comes from the terminal view; resizes are forwarded.
- Host key identity string (`KnownHost.hostPort`): `host` when port is 22, otherwise `[host]:port` (OpenSSH `known_hosts` convention). Fingerprint format: `SHA256:` + base64 (no padding) of SHA-256 over the public key wire blob — identical to `ssh-keygen -l`.
- Host keys: unknown → ask the user (never auto-accept); match → continue; changed → block the connection and show old and new fingerprints, with "Remove old key and trust new" as an explicit action.
- Secrets (passwords, private keys, passphrases) never appear in process arguments, environment variables, logs, errors or descriptions. Temporary files live in `~/Library/Application Support/TermiusReimagined/run/` (directory 0700, files 0600), are removed when the session connects or ends (whichever first), and the directory is emptied at app launch.
- System ssh command line (exact flags; values in angle brackets):
  `/usr/bin/ssh -tt -p <port> -l <user> -o UserKnownHostsFile=<run>/known_hosts -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o ControlMaster=auto -o ControlPath=<run>/cm-%C -o ControlPersist=15 -o ServerAliveInterval=30 [-o IdentitiesOnly=yes -i <run>/<uuid>.key] -- <host>`
  Password and key passphrase are provided only through `SSH_ASKPASS=<run>/askpass` with `SSH_ASKPASS_REQUIRE=force` and `DISPLAY=:0`, the helper reading a one-time 0600 secret file whose path is in `TR_SECRET_FILE`, then deleting it. When no secret is stored, no askpass variables are set and ssh prompts inside the terminal.
- System-ssh host keys: before launching ssh, run `/usr/bin/ssh-keyscan -T 10 -p <port> -t ed25519,ecdsa,rsa <host>`, evaluate the returned keys with the same trust rules (prefer ed25519, then ecdsa, then rsa), and write the trusted line(s) to `<run>/known_hosts` built from the vault's `KnownHost` records.
- A remote end of session (including Citadel's `Already closed`) is a normal disconnect, never an error dialog.
- Mac checkpoint at the end: Cory builds, runs the tests, and connects to real hosts (one password host, one Ed25519-key host, one RSA-key host via system ssh, and the Synology).

## Review Focus

1. **Changed host key** (possible man-in-the-middle): the connection is blocked before any credential is sent, with a clear warning; never silently accepted. → tests in Tasks 3, 4, 5.
2. **Remote exit or network drop mid-session:** the tab shows a disconnected banner with Reconnect, scrollback stays, nothing crashes. → tests in Tasks 4, 5, 6.
3. **Wrong password or rejected key:** a clear error, retry possible, stored credentials untouched unless the user chooses to save the new password. → tests in Tasks 4, 6.
4. **Secret leakage:** no secret in `ps` output (arguments/environment), logs or errors; temp files gone after success and after failure. → tests in Task 5.
5. **Heavy output / fast typing:** large output (e.g. 5 MB) arrives complete and in order; input bytes are sent in order. → tests in Tasks 4, 5.

---

## File Structure

```
Packages/CoreSSH/
  Package.swift                                   platforms 15/18; Citadel dep; SSHCore target + tests
  Sources/CoreModels/Models.swift                 Host.useSystemSSH: Bool? (nil = false)
  Sources/SSHCore/
    TerminalSession.swift                         protocol, SessionEvent, SessionError, ConnectionPlan types
    HostKeyTrust.swift                            HostKeyCandidate, HostKeyDecision, HostKeyEvaluator protocol, fingerprint/hostPort helpers
    CitadelSession.swift                          Citadel engine
    SystemSSH/PTYProcess.swift                    forkpty-based child process with pty I/O
    SystemSSH/SystemSSHSession.swift              system ssh engine
    SystemSSH/SSHRuntimeDirectory.swift           run dir, askpass helper, secret files, known_hosts writer, cleanup
  Sources/AppCore/
    Domain/ConnectionPlanner.swift                Host/QuickConnect → ConnectionPlan
    Domain/OSDetector.swift                       uname/os-release → OSBadge
    Domain/KnownHostsStore.swift                  vault-backed HostKeyEvaluator + known_hosts lines
    Sessions/SessionManager.swift                 open/close/reconnect, state machine, logs, OS detection, startup snippet
    ViewModels/LogsViewModel.swift
  Tests/SSHCoreTests/ (TestSSHServer.swift helper + engine tests), Tests/AppCoreTests/…
App/
  project.yml                                     macOS 15; SwiftTerm package; SSHCore product
  Sources/UI/Terminal/TerminalTabView.swift, SwiftTermView.swift, HostKeyPrompt.swift, PasswordPrompt.swift, DisconnectedBanner.swift
  Sources/UI/Logs/LogsView.swift
  Sources/UI/TopBarView.swift, RootView.swift, Hosts/* (enable Connect)
```

---

### Task 1: SSHCore target, macOS 15, host flag, OS detection, fingerprints

**Files:** Modify `Packages/CoreSSH/Package.swift`, `Sources/CoreModels/Models.swift`; Create `Sources/SSHCore/HostKeyTrust.swift`, `Sources/AppCore/Domain/OSDetector.swift`; Tests `Tests/SSHCoreTests/HostKeyTrustTests.swift`, `Tests/AppCoreTests/OSDetectorTests.swift`, `Tests/CoreModelsTests/ModelsTests.swift`

**Interfaces:**
- Produces:
  - Package: platforms per Global Constraints; library product `SSHCore` (depends `CoreModels`, `Citadel`, `Crypto`); `AppCore` gains a dependency on `SSHCore`; test target `SSHCoreTests`.
  - `Host.useSystemSSH: Bool?` (memberwise default nil; existing vault files without the key still decode).
  - `enum HostKeyFormat { static func hostPort(host: String, port: Int) -> String; static func fingerprintSHA256(publicKeyBlob: Data) -> String }`
  - `struct HostKeyCandidate: Sendable, Equatable { var hostPort: String; var keyType: String; var publicKeyBlob: Data; var fingerprint: String }` with `init(host:port:keyType:publicKeyBlob:)` computing the other fields.
  - `enum HostKeyDecision: Sendable, Equatable { case trusted, rejected }`; `enum HostKeyCheck: Sendable, Equatable { case known, unknown, changed(previousFingerprint: String) }`
  - `protocol HostKeyEvaluator: Sendable { func evaluate(_ candidate: HostKeyCandidate) async -> HostKeyDecision }` (implemented in Task 3; the session engines call it).
  - `enum OSDetector { static let probeCommand = "uname -s; cat /etc/os-release 2>/dev/null; cat /etc/synoinfo.conf 2>/dev/null | head -1" ; static func badge(fromProbeOutput: String) -> OSBadge? }`

- [ ] **Step 1: Failing tests**
```swift
func testHostPortFormatting()                 // ("10.0.0.5",22) → "10.0.0.5"; ("10.0.0.5",2222) → "[10.0.0.5]:2222"; ("fe80::1",22) → "fe80::1"
func testFingerprintMatchesSSHKeygen()        // fixed ed25519 blob → known "SHA256:…" string (compute expected with `ssh-keygen -l` in the sandbox, embed as literal)
func testOldVaultHostWithoutFlagDecodes()     // JSON without "useSystemSSH" decodes, flag nil
func testDetectsUbuntuDebianRaspbianFedoraAlpineArchRHEL() // os-release fixtures with ID=… / ID_LIKE=…
func testDetectsMacOSAndFreeBSD()             // "Darwin\n" → .macOS; "FreeBSD\n" → .freeBSD
func testDetectsSynologyAndHomeAssistant()    // synoinfo line → .synology; os-release ID=haos → .homeAssistant
func testUnknownLinuxFallsBackToLinux()       // "Linux\n" with unknown ID → .linux; empty → nil
```
- [ ] **Step 2–4:** fail → implement → pass (`swift test -Xlinker --allow-shlib-undefined`). First build fetches Citadel and SwiftNIO (several minutes).
- [ ] **Step 5: Commit** `feat(ssh-core): SSHCore target, host key formats, OS detection`

---

### Task 2: Connection planning

**Files:** Create `Sources/SSHCore/TerminalSession.swift` (types only), `Sources/AppCore/Domain/ConnectionPlanner.swift`; Test `Tests/AppCoreTests/ConnectionPlannerTests.swift`

**Interfaces:**
- Produces (in SSHCore, all `Sendable`):
  - `enum SSHEngine: Sendable, Equatable { case citadel, systemSSH }`
  - `enum SSHCredential: Sendable { case password(String), privateKey(type: KeyType, pem: String, passphrase: String?), none }` with a redacting `description`.
  - `struct ConnectionPlan: Sendable { var hostID: UUID?; var label: String; var host: String; var port: Int; var username: String; var credential: SSHCredential; var engine: SSHEngine; var startupScript: String? }`
- Produces (in AppCore): `enum ConnectionPlanner { static func plan(hostID: UUID, vault: LocalVault) throws -> ConnectionPlan; static func plan(quickConnect: QuickConnectTarget, defaultUsername: String) -> ConnectionPlan }` (`@MainActor` where it reads the vault); `enum ConnectionPlanError: Error, Equatable, LocalizedError { case hostNotFound, missingAddress, missingUsername }`.
- Rules: effective identity via `HostDirectory.effectiveIdentityID` unless the host has direct credentials; username from host, else identity; password from host or identity; key from host `sshKeyID`, else identity's key; key wins over password when both exist (password kept for keyboard prompts is out of scope); port via `effectivePort`; engine per Global Constraints; `startupScript` from the host's startup snippet if set and not deleted. Quick connect: username from target or `defaultUsername` (the Mac user name, passed in), `.none` credential, engine `.citadel`.

- [ ] **Step 1: Failing tests**
```swift
func testDirectPasswordHost()
func testIdentityProvidesUsernamePasswordAndKey()
func testGroupDefaultIdentityIsInherited()
func testKeyWinsOverPassword()
func testRSAKeySelectsSystemSSH()             // ed25519 key → .citadel; rsa key → .systemSSH
func testUseSystemSSHFlagSelectsSystemSSH()
func testInheritedPortAndStartupSnippet()
func testMissingAddressOrUsernameThrows()
func testQuickConnectUsesDefaultUsernameAndCitadel()
func testCredentialDescriptionIsRedacted()
```
- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** `feat(app-core): connection planning and engine choice`

---

### Task 3: Known-hosts trust store

**Files:** Create `Sources/AppCore/Domain/KnownHostsStore.swift`; Test `Tests/AppCoreTests/KnownHostsStoreTests.swift`

**Interfaces:**
- Consumes: `HostKeyCandidate`, `HostKeyCheck`, `HostKeyDecision`, `HostKeyEvaluator`, `KnownHost` model, `LocalVault`.
- Produces: `@MainActor final class KnownHostsStore { init(vault: LocalVault) ; func check(_ c: HostKeyCandidate) -> HostKeyCheck ; func trust(_ c: HostKeyCandidate) ; func replace(_ c: HostKeyCandidate) /* tombstones every KnownHost for that hostPort, then trusts */ ; func knownHostsFileLines() -> [String] /* "<hostPort> <keyType> <base64 blob>" for each live record */ }`. `KnownHost` gains `publicKeyBase64: String?` if not present (optional → old records decode; lines are only produced for records that have it).
  - `struct PromptingHostKeyEvaluator: HostKeyEvaluator { init(store: KnownHostsStore, ask: @escaping @Sendable @MainActor (HostKeyCandidate, HostKeyCheck) async -> HostKeyDecision) }` — known → `.trusted` without asking; unknown → ask, and on `.trusted` call `trust`; changed → ask with `.changed`, and on `.trusted` call `replace` (the UI only returns `.trusted` here after the explicit "Remove old key and trust new" action).
- [ ] **Step 1: Failing tests**
```swift
func testUnknownKeyAsksAndTrustStoresRecord()
func testKnownKeyIsTrustedWithoutAsking()
func testChangedKeyAsksWithPreviousFingerprintAndRejectionKeepsOldRecord()
func testReplaceTombstonesOldRecords()
func testKnownHostsFileLinesFormat()          // matches OpenSSH known_hosts syntax; skips records without publicKeyBase64
func testDifferentPortsAreDifferentHosts()
```
- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** `feat(app-core): known hosts trust store`

---

### Task 4: Citadel engine

**Files:** Modify `Sources/SSHCore/TerminalSession.swift`; Create `Sources/SSHCore/CitadelSession.swift`, `Tests/SSHCoreTests/TestSSHServer.swift`, `Tests/SSHCoreTests/CitadelSessionTests.swift`

**Interfaces:**
- Produces in `TerminalSession.swift`:
  - `enum SessionEvent: Sendable, Equatable { case connected, output([UInt8]), closed(SessionEndReason) }`; `enum SessionEndReason: Sendable, Equatable { case remoteClosed, userClosed, failed(SessionError) }`
  - `enum SessionError: Error, Sendable, Equatable, LocalizedError { case hostKeyRejected, hostKeyChanged(previous: String, presented: String), authenticationFailed, connectionFailed(String), unsupportedKey(String), timedOut }` — messages contain no secrets.
  - `protocol TerminalSession: AnyObject, Sendable { var events: AsyncStream<SessionEvent> { get }; func start(cols: Int, rows: Int) async; func send(_ bytes: [UInt8]) async; func resize(cols: Int, rows: Int) async; func runCommand(_ command: String) async throws -> String /* separate exec, merged streams, 1 MB cap */; func close() async }`
- Produces: `final class CitadelSession: TerminalSession` (actor-backed internals) — `init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator, connectTimeout: Duration = .seconds(15))`. Auth: password → `.passwordBased`; ed25519 key → `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)` with the passphrase as UTF-8; RSA or `.none` with no password → `.failed(.unsupportedKey("rsa"))` / prompt is SessionManager's job. Host key validator: custom delegate that converts the presented key to a `HostKeyCandidate` and calls the evaluator; `.rejected` → fail the handshake with `.hostKeyRejected`. Output pumped from `TTYOutput` (stdout and stderr both to `.output`) in order; Citadel's `Already closed` at the end → `.closed(.remoteClosed)`.
- `TestSSHServer` (test helper): starts `/usr/sbin/sshd -D -f <tmp>/sshd_config -p <free port>` with a temp host key and `AuthorizedKeysFile <tmp>/authorized_keys`, `PasswordAuthentication yes`, runs as root with a test user created on demand (`useradd`, `chpasswd`); `XCTSkip` when not root or sshd missing; stops in `tearDown`.

- [ ] **Step 1: Failing tests** (all against `TestSSHServer`)
```swift
func testPasswordLoginRunsShellAndEchoes()          // send "echo hi\n" → output contains "hi"
func testEd25519KeyLoginWithAndWithoutPassphrase()  // keys from AppCore SSHKeyGenerator / ssh-keygen -N
func testWrongPasswordFailsWithAuthenticationFailed()
func testRSAKeyIsReportedUnsupported()
func testUnknownHostKeyRejectedStopsBeforeAuth()    // evaluator returns .rejected → .failed(.hostKeyRejected); server log shows no auth attempt
func testRemoteExitIsRemoteClosedNotError()         // send "exit\n" → .closed(.remoteClosed)
func testLargeOutputArrivesCompleteAndInOrder()     // `head -c 5000000 /dev/zero | tr '\\0' 'a'; echo END` → 5,000,000 'a' then END
func testResizeChangesRemoteSize()                  // resize(100,40) then "stty size\n" → "40 100"
func testRunCommandReturnsMergedOutput()            // runCommand(OSDetector.probeCommand) contains "Linux"
func testCloseByUserEndsWithUserClosed()
```
- [ ] **Step 2–4:** fail → implement → pass. The Linux sandbox has `sshd` installed (`apt-get install openssh-server` if missing).
- [ ] **Step 5: Commit** `feat(ssh-core): Citadel terminal session engine`

---

### Task 5: System ssh engine

**Files:** Create `Sources/SSHCore/SystemSSH/PTYProcess.swift`, `SSHRuntimeDirectory.swift`, `SystemSSHSession.swift`; Tests `Tests/SSHCoreTests/PTYProcessTests.swift`, `SystemSSHSessionTests.swift`

**Interfaces:**
- Produces:
  - `final class PTYProcess: Sendable` — `init(executable: String, arguments: [String], environment: [String: String], cols: Int, rows: Int) throws` (uses `forkpty`; child gets only the given environment plus `PATH`, `HOME`, `USER`, `LANG`, `TERM=xterm-256color`); `output: AsyncStream<[UInt8]>`; `func write(_:)`; `func resize(cols:rows:)` (`TIOCSWINSZ`); `func terminate()`; `exitStatus: Int32?` after the stream ends.
  - `struct SSHRuntimeDirectory: Sendable` — `init(root: URL)` (app passes `…/TermiusReimagined/run`); `func prepare() throws` (creates 0700, writes the `askpass` helper 0700); `func clean() throws` (removes everything inside); `func writeSecret(_ s: String) throws -> URL` (0600, unique name); `func writeKey(_ pem: String) throws -> URL` (0600); `func writeKnownHosts(_ lines: [String]) throws -> URL`. The askpass helper is a `/bin/sh` script: `#!/bin/sh` / `f="$TR_SECRET_FILE"` / `[ -n "$f" ] && [ -f "$f" ] && cat "$f" && rm -f "$f"` — it never echoes the prompt.
  - `final class SystemSSHSession: TerminalSession` — `init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator, knownHostsLines: @Sendable () async -> [String], runtime: SSHRuntimeDirectory, sshPath: String = "/usr/bin/ssh", keyscanPath: String = "/usr/bin/ssh-keyscan")`. `start`: keyscan → parse lines → `HostKeyCandidate` per type (prefer ed25519, ecdsa, rsa) → evaluate (rejected → `.failed(.hostKeyRejected)`; no keys → `.failed(.connectionFailed("…"))`) → write known_hosts (vault lines + newly trusted) → write key/secret files as needed → launch ssh with the exact flags from Global Constraints → stream output; delete key and secret files after the first output byte or on exit, whichever first. `runCommand` launches `ssh` with the same options plus `-T -o BatchMode=yes <host> -- <command>` reusing the ControlMaster socket. Exit status 255 before any output → `.failed(.connectionFailed(<last stderr line without secrets>))`; otherwise `.closed(.remoteClosed)`.

- [ ] **Step 1: Failing tests**
```swift
// PTYProcessTests
func testRunsCommandAndCollectsOutput()        // /bin/echo hello
func testWriteAndResize()                       // /bin/sh -c 'stty size; read x; echo got:$x' after resize(90,30), write "z\n" → "30 90", "got:z"
func testTerminateEndsStream()
// SystemSSHSessionTests (TestSSHServer from Task 4)
func testPasswordLoginThroughAskpass()
func testRSAKeyLoginWorks()                     // the case Citadel can't do
func testEncryptedKeyPassphraseThroughAskpass()
func testUnknownHostKeyRejectedNeverLaunchesSSH()
func testChangedHostKeyIsReported()             // vault lines hold a different key for the host → evaluator sees .changed
func testSecretsNeverInArgumentsOrEnvironment() // while connected, read /proc/<ssh pid>/cmdline and /proc/<pid>/environ: no password, no passphrase, no key PEM
func testTempFilesRemovedAfterConnectAndAfterFailure()
func testRunCommandReusesConnection()           // runCommand(OSDetector.probeCommand) succeeds without a second password
func testRemoteExitIsRemoteClosed()
func testLargeOutputArrivesCompleteAndInOrder()
```
- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** `feat(ssh-core): system ssh engine with pty, askpass and keyscan trust`

---

### Task 6: SessionManager

**Files:** Create `Sources/AppCore/Sessions/SessionManager.swift`; Test `Tests/AppCoreTests/SessionManagerTests.swift` (uses a scripted fake `TerminalSession` and fake engine factory)

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class TerminalTab: Identifiable { let id: UUID; private(set) var title: String; private(set) var badge: OSBadge?; private(set) var state: State; var outputSink: (@MainActor ([UInt8]) -> Void)? /* set by the terminal view */ ; enum State: Equatable { case connecting, awaitingHostKey(HostKeyCandidate, HostKeyCheck), awaitingPassword(prompt: String), connected, disconnected(String?) } }`
  - `@MainActor @Observable final class SessionManager { init(vault: LocalVault, knownHosts: KnownHostsStore, makeSession: @escaping @MainActor (ConnectionPlan, any HostKeyEvaluator) -> any TerminalSession, deviceName: String, defaultUsername: String) ; private(set) var tabs: [TerminalTab]; var selectedTabID: UUID? ; func open(hostID: UUID) throws -> TerminalTab ; func open(quickConnect: QuickConnectTarget) -> TerminalTab ; func answerHostKey(tabID: UUID, _ decision: HostKeyDecision) ; func providePassword(tabID: UUID, _ password: String, save: Bool) ; func send(tabID: UUID, _ bytes: [UInt8]) ; func resize(tabID: UUID, cols: Int, rows: Int) ; func reconnect(tabID: UUID) ; func close(tabID: UUID) ; func closeAll() async }`
  - Behavior:
    - Output bytes are buffered until `outputSink` is set, then delivered in order.
    - On `.connected`: create a `ConnectionLog` (host label, username, device name, start); set host `lastConnectedAt`; run `OSDetector.probeCommand` once per host via `runCommand` and save the badge unless `osBadgeIsManual`; send the startup script followed by `\n`.
    - On `.closed`: set the log's `endedAt`; state `.disconnected(reason message or nil)`; keep the tab and its scrollback (the view keeps the terminal).
    - `.none` credential with Citadel: state `.awaitingPassword("Password for user@host")`; `providePassword` restarts the connection with that password, and `save: true` writes it to the host (direct credentials) through `saveNow`.
    - Authentication failure with a stored password: state `.awaitingPassword("Password for user@host (the saved one was rejected)")`; stored credentials change only when `save` is true.
    - `reconnect` reuses the same tab (new session, new log).
    - `closeAll` closes every session and awaits their end (used at quit).

- [ ] **Step 1: Failing tests**
```swift
func testOpenCreatesTabAndConnects()
func testOutputIsBufferedUntilSinkThenInOrder()
func testConnectedWritesLogAndLastConnected()
func testOSDetectionUpdatesBadgeUnlessManual()
func testStartupScriptIsSentAfterConnect()
func testRemoteCloseKeepsTabAndEndsLog()
func testHostKeyPromptFlow()                  // fake session asks evaluator → tab state .awaitingHostKey → answer .trusted → connected
func testMissingPasswordPromptsAndSaveStoresIt()
func testRejectedPasswordPromptsWithoutChangingStoredCredentials()
func testReconnectReusesTab()
func testCloseAllEndsEverySession()
```
- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** `feat(app-core): session manager with logs, OS detection and prompts`

---

### Task 7: Logs view model

**Files:** Create `Sources/AppCore/ViewModels/LogsViewModel.swift`; Test `LogsViewModelTests.swift`

**Interfaces:** `@MainActor @Observable final class LogsViewModel { init(vault: LocalVault); var rows: [Row] /* newest first */; func toggleSaved(id:) ; struct Row: Identifiable { id, dateText ("Jun 26, 2026"), timeRangeText ("23:45 - 23:15 (+1d)", "07:05 - …" while open), deviceName, hostLabel, username, badge, saved } }` — dates in the Mac's current time zone with fixed `en_US_POSIX` formats `MMM dd, yyyy` and `HH:mm`; "(+Nd)" when the end is on a later calendar day.
- [ ] **Step 1: Failing tests**
```swift
func testRowsNewestFirst()
func testTimeRangeAcrossMidnightShowsPlusDays()
func testOpenSessionShowsEllipsis()
func testToggleSavedPersists()
func testBadgeComesFromHostIfStillPresent()
```
- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** `feat(app-core): logs view model`

---

### Task 8: Terminal tabs in the app

**Files:** Modify `App/project.yml` (macOS 15, SwiftTerm package, SSHCore product), `App/Sources/AppEnvironment.swift` (create `SSHRuntimeDirectory` + `prepare()`/`clean()` at launch, `KnownHostsStore`, `SessionManager` with a factory choosing `CitadelSession` or `SystemSSHSession` by `plan.engine`), `App/Sources/AppDelegate.swift` (await `sessionManager.closeAll()` before the vault flush), `UI/TopBarView.swift` (session tabs: badge + title + close button, selected styling, middle-click close not required), `UI/RootView.swift` (show the selected tab's terminal or the Vaults screens), `UI/Hosts/HostsView.swift` + `HostDetailsPanel.swift` + `HostCardView.swift` (enable Connect; double-click card connects; quick-connect Connect opens a tab); Create `UI/Terminal/SwiftTermView.swift`, `TerminalTabView.swift`, `HostKeyPrompt.swift`, `PasswordPrompt.swift`, `DisconnectedBanner.swift`.

**Interfaces:**
- `SwiftTermView: NSViewRepresentable` wrapping SwiftTerm's macOS `TerminalView`; its delegate forwards `send(source:data:)` to `sessionManager.send`, `sizeChanged` to `resize`; `tab.outputSink` feeds bytes with `feed(byteArray:)` on the main actor; the `TerminalView` instance is kept per tab (stored on the coordinator keyed by tab id) so switching tabs and reconnecting keep scrollback. Font: SF Mono 13 pt; colors: a light theme matching the content background in light mode and a dark theme in dark mode (themes proper arrive in milestone 5).
- Host key prompt (sheet on the terminal tab): unknown → title "Trust this server?", host, key type, fingerprint, buttons "Cancel" and "Trust and Connect"; changed → red warning "The server's identity has changed", previous and new fingerprints, explanation that this can mean someone is intercepting the connection, buttons "Cancel" (default) and "Remove Old Key and Trust New".
- Password prompt (sheet): secure field, "Save password" checkbox, Connect / Cancel.
- Disconnected banner at the top of the terminal: message ("Connection closed" or the error) and a Reconnect button; Cmd+R reconnects while it shows.
- Keyboard: Cmd+W closes the selected terminal tab (asks for confirmation when connected); Cmd+1…9 select tabs (Vaults is Cmd+1).
- Also fix the milestone-2 leftovers: the vault-unreadable failure screen says "Your old data is kept at <path>. Starting fresh creates a new, empty vault." with the button "Start with an Empty Vault"; the generic failure keeps "Try Again"; `.task` no longer re-runs a failed load automatically; the quit alert calls `NSApp.activate()` first.
- [ ] **Step 1: Implement** (no new logic beyond wiring view models). Verify in the sandbox with `swiftc -parse` on every changed/new file and keep both packages' suites green.
- [ ] **Step 2: Commit** `feat(app): terminal tabs with SwiftTerm, host key and password prompts`

---

### Task 9: Logs screen

**Files:** Create `App/Sources/UI/Logs/LogsView.swift`; Modify `UI/RootView.swift`
**Interfaces:** Consumes `LogsViewModel`. A table matching Cory's Logs screenshot: columns Date (date + time range), User (device name), Host (badge + label + "ssh, <user>"), Saved (bookmark toggle). No "upgrade" banner.
- [ ] **Step 1: Implement**; `swiftc -parse`.
- [ ] **Step 2: Commit** `feat(app): connection logs screen`

---

### Task 10: Mac checkpoint (Cory)

- [ ] **Step 1:** From the repo: `cd App && xcodegen generate && xcodebuild -project TermiusReimagined.xcodeproj -scheme TermiusReimagined -destination 'platform=macOS' test 2>&1 | tail -40` → `** TEST SUCCEEDED **`.
- [ ] **Step 2:** Run the app and connect to: a password host (e.g. Docker Server), a host using your Ed25519 key, a host using your RSA key (should go through system ssh automatically), and the Synology. For each: the fingerprint prompt appears the first time only, the OS badge updates, `top` or `htop` renders correctly, resizing the window reflows, `exit` shows the Reconnect banner, and the Logs screen lists the session.
- [ ] **Step 3:** Paste any build errors or describe anything that misbehaves; fixes go in as follow-up commits.
