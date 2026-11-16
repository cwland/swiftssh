# Citadel — local patch

This is Citadel 0.12.1 (https://github.com/orlandos-nl/Citadel, revision `ae8562f`, MIT licence, see
`LICENSE`), vendored so SwiftSSH can tell **how an interactive shell ended** and can **offer several keys in one
login**. Only `Sources/Citadel/TTY/Client/TTY.swift` and `Sources/Citadel/SSHAuthenticationMethod.swift`
are changed; every change is marked `PATCH (SwiftSSH)`.
The example server and the tests are left out.

## Why

Upstream records a shell's `exit-status` but ignores `exit-signal`, and finishes the output stream
normally both when the user typed `exit` and when the server killed the shell (reboot, shutdown, sshd
restart). The app closes the tab for the first and reconnects for the second, so it needs to know.
(`CitadelSession` treats `CommandSignaled` as a lost connection and `EndedWithoutExitStatus` as a
normal logout, since some appliances never send an exit status.)

## What changed

- `ExecCommandHandler.Output.exitSignal(String)`: the handler now reports `SSHChannelRequestEvent.ExitSignal`
  (RFC 4254 §6.10) instead of passing it on unhandled.
- The command stream finishes by throwing:
  - `SSHClient.CommandSignaled(signal:)` when an exit signal arrived (any mode);
  - `SSHClient.EndedWithoutExitStatus()` when a **PTY** shell's channel ends with neither an exit status
    nor a signal. Exec commands and `withTTY` keep upstream's behaviour.
- `SSHClient.CommandFailed` (non-zero exit status) and a zero exit status are unchanged.

## Several keys in one login

Upstream asks a `.custom` authentication delegate once and then gives up. SwiftSSH on iPhone/iPad offers
the keys imported there one after another (`KeyCandidatesAuthentication` in `CitadelSession`), so
`SSHAuthenticationMethod.nextAuthenticationType` now keeps a custom delegate and asks it again after
the server refuses an offer; the delegate fails the promise when it has nothing left. Built-in methods
(`.passwordBased`, `.ed25519`, …) are still offered once each. A custom delegate that wraps a single
built-in method (`ProgressReportingAuthentication`) ends the same way as before: its inner method fails
with `allAuthenticationOptionsFailed` on the second ask.

## Updating Citadel

Copy the new release's `Sources` over this one, re-apply the marked changes in `TTY.swift` and `SSHAuthenticationMethod.swift`, update the
revision above, and run `swift test` in `Packages/CoreSSH` (`CitadelSessionTests` covers the endings).
