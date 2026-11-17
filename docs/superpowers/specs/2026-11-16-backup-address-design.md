# Backup address — design (approved by Cory 2026-11-16)

## Intent
A host can have a second address (typically its Tailscale IP or MagicDNS name) that is used when the
main address can't be reached — e.g. away from home. Works in the Mac app, the iPhone/iPad app, and
through sync.

## Behaviour
- **Model:** `SavedHost` gains an optional backup address (e.g. `fallbackAddress: String?`), synced like
  every other host field. Missing in older records = no backup. Older app versions keep the field
  (forward-compatible sync already preserves unknown fields — verify with a test).
- **Same port, username and credentials** as the main address. No separate port.
- **Connect order:** try the main address first, with a **5-second** limit on reaching it (TCP connect;
  for System SSH, the equivalent of `ConnectTimeout=5`). If the main address **can't be reached**
  (timeout, connection refused, no route/host unreachable, name not resolved), try the backup address
  immediately, with the normal timeout.
- **No fallback** when the main address was reached but the session failed later: authentication
  failures, rejected keys, host-key mismatch/refusal, user cancel. Those surface as today.
- With no backup address set, behaviour is unchanged (including the normal connect timeout — the
  5-second limit only applies when a backup exists).
- **Both engines on the Mac** (built-in Citadel and System SSH) and the built-in engine on iOS.
  Also applies to reconnects/auto-reconnect and workspace sessions (anything going through the session
  manager's connect path).
- **Connection log** records both attempts ("Main address 192.168.50.10 unreachable (timed out);
  trying backup address 100.x.y.z…"). The session/tab shows which address it ended up on (e.g. in the
  connection log header / tab subtitle where the address is shown today).
- **Host keys:** known hosts stay keyed by the address actually used. When connecting to the backup
  address, a host key that is **already trusted for the main address** (same host, same port) is
  accepted without a prompt (and may be recorded for the backup address too). A different/unknown key
  gets the normal new-key prompt; a mismatch with an existing entry for the backup address is the
  normal mismatch error.
- **Mac UI:** Host Details gets an optional "Backup address" field under Address, with help text
  ("Tried if the address above can't be reached, e.g. a Tailscale IP"). Saved like other fields
  (immediately). Host cards may show nothing new. Search may match the backup address.
- **iOS UI:** host details (read-only) show "Backup address" when set. iOS still never edits hosts.
- Quick-connect / ad-hoc `user@host` connections have no backup.

## Non-goals
- More than two addresses; per-address ports/usernames; remembering which address worked last;
  network-based (SSID) selection; group-level backup addresses.

## Constraints
- TDD for all logic (planner, fallback decision/orchestration, host-key acceptance rule, model coding).
- Secrets never in logs/errors/args/env. Never touch a real ~/.ssh in tests.
- Swift 6; App targets can only be syntax-checked on Linux (`swiftc -parse`); CI on GitHub compiles
  both apps (`.github/workflows/ios.yml` runs on pushes to main).
