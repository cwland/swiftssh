# Citadel — local patch

This is Citadel 0.12.1 (https://github.com/orlandos-nl/Citadel, revision `ae8562f`, MIT licence, see
`LICENSE`), vendored so SwiftSSH can tell **how an interactive shell ended**. Only
`Sources/Citadel/TTY/Client/TTY.swift` is changed; every change is marked `PATCH (SwiftSSH)`.
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

## Updating Citadel

Copy the new release's `Sources` over this one, re-apply the marked changes in `TTY.swift`, update the
revision above, and run `swift test` in `Packages/CoreSSH` (`CitadelSessionTests` covers the endings).
