# Backup address — implementation plan

Spec: `docs/superpowers/specs/2026-11-16-backup-address-design.md` (binding). Branch `backup-address`.
TDD throughout; package tests with `swift test -Xlinker --allow-shlib-undefined` (engine tests in
`SSHCoreTests` run on Linux too, against the in-process test server / local ssh). App files: `swiftc -parse`;
both apps compile in CI (`gh workflow run ios.yml --ref backup-address`).

## Interfaces

```swift
// CoreModels.Host
public var fallbackAddress: String?          // synced, optional, top level; init(..., fallbackAddress: String? = nil, ...)

// SSHCore.ConnectionPlan
public var fallbackHost: String?             // backup address (trimmed, non-empty, ≠ host); nil = none
public var reachTimeout: Duration?           // limit on reaching the server (DNS + TCP); nil = connectTimeout covers it

// SSHCore.SessionError
case unreachable(String)                     // the server couldn't be reached (DNS, refused, no route, …);
                                             // same user text as connectionFailed ("The connection failed: …")

// AppCore/Sessions/ConnectionFallback.swift (pure)
enum ConnectionFallback {
    static let reachTimeout: Duration                                   // 5 s
    static func backupAddress(main: String, backup: String?) -> String? // trimmed, nil when empty or same as main
    static func reachesServer(_ step: ConnectionStep) -> Bool           // .connected(address:), handshake, auth, shell…
    static func shouldTryBackup(after: SessionEndReason, reachedServer: Bool) -> Bool
    static func reason(of: SessionError) -> String                      // "timed out", "connection refused", …
    static func note(main: String, reason: String, backup: String) -> String
}

// AppCore.PromptingHostKeyEvaluator
init(store:, alsoTrusting mainHostPort: String? = nil, ask:)            // backup attempts: accept a key trusted for main

// AppCore.TerminalTab
public var currentAddress: String?           // address the current attempt uses (shown in the connection screen header)
public var isUsingBackupAddress: Bool

// AppCore.HostDetailsViewModel
public var fallbackAddress: String           // "" = none (stored nil)
// AppCore.CompanionHostDetails
public let fallbackAddress: String?
```

## Tasks

1. **Model + sync** — `Host.fallbackAddress`. Tests (CoreModelsTests/ModelsTests): round trip; an older
   record without the field decodes as nil. Test (SyncCoreTests): an older build's model (no such field)
   re-encoding a record keeps `fallbackAddress` (`PlainRecord(_:deviceID:keepingUnknownFieldsOf:)`), and
   the new model reads it back.
2. **Planner** — `ConnectionPlan.fallbackHost` / `reachTimeout`; `ConnectionPlanner` sets `fallbackHost`
   for Mac and iOS plans (trimmed; nil when blank or equal to the address); quick connect never.
   Tests in ConnectionPlannerTests / ConnectionPlannerIOSTests.
3. **Fallback decision** — `ConnectionFallback` + `SessionError.unreachable`. Pure tests.
4. **Session manager** — main attempt gets `reachTimeout = 5 s` only when a backup exists; when it ends
   `.failed(.timedOut | .unreachable)` before the server was reached (no `.connected(address:)`/handshake/
   auth step and no `.connected` event), the log marks the step failed, adds the note line, and a new
   attempt starts on the backup (same credential — 1Password secrets are not read again — normal
   timeouts, host key evaluator that also trusts the main address's key). Header/`currentAddress` show
   the backup. Auth/host-key/cancel/after-reach failures: unchanged. Auto-reconnect: `.unreachable`
   counts as a drop; each try goes main → backup. Workspaces use the same connect path. Tests in
   `SessionManagerBackupAddressTests`.
5. **Host key rule** — `PromptingHostKeyEvaluator(alsoTrusting:)`: `.unknown`/`.newKeyType` on the backup
   with a key `.known` for the main host:port → recorded for the backup and trusted, no prompt;
   `.changed` → normal prompt. Tests in KnownHostsStoreTests.
6. **Citadel** — reach watchdog (`reachTimeout`: DNS + TCP must finish in time, else `.timedOut`), TCP
   connect budget `min(reach, connect)`; `TCPConnectFailure` (not timed out) and `NameResolutionFailure`
   → `.unreachable`. Tests: budget function, refused port → `.unreachable`, unresolvable name →
   `.unreachable`.
7. **System SSH** — `ssh-keyscan -T` and `ConnectTimeout` use the reach limit when set; keyscan failure →
   `.unreachable("Could not reach …")`; `classifyFailure`: "ssh: connect to host … port …: …" and
   "ssh: Could not resolve hostname …" → `.unreachable`; banner-exchange timeouts and everything else
   unchanged. Tests in SystemSSHSessionTests.
8. **Mac UI** — Host Details "Backup address" field under Address with help text, saved at once;
   `HostDirectory.filter(search:)` matches it; connection screen header shows `tab.currentAddress`.
9. **iOS UI** — `CompanionHostDetails.fallbackAddress`; HostDetailsSheet row "Backup address" when set;
   iOS connection screen header shows the address in use.
10. **Verify** — full package suite, `swiftc -parse` on touched App files, CI green, report.
