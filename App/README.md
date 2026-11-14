# Termius Reimagined — Mac app

SwiftUI app target for macOS 14+. All logic lives in the `CoreSSH` package
(`../Packages/CoreSSH`, products `AppCore`, `CoreModels`, `SyncCore`); this folder holds only
the window, views and platform glue (Keychain).

The Xcode project is generated from `project.yml` and is not committed.

## Build, test and run

```
brew install xcodegen
cd App && xcodegen generate
xcodebuild -project TermiusReimagined.xcodeproj -scheme TermiusReimagined -destination 'platform=macOS' test
open TermiusReimagined.xcodeproj   # then Run (Cmd+R)
```

If the test target fails with a "missing required module" (or "no such module 'AppCore'")
error, see the fallback list in the Task 9 report: add the `AppCore` and `SyncCore` package
products to the `TermiusReimaginedTests` dependencies in `project.yml` and regenerate.

When the app runs as the unit-test host it skips loading the vault and Keychain key, so tests
never touch your real vault.

Re-run `xcodegen generate` whenever files are added or removed under `Sources/` or `Tests/`.

## Where things are stored

- Vault: `~/Library/Application Support/TermiusReimagined/vault.bin` (AES-256-GCM).
  A vault that cannot be read is renamed to `vault.bin.unreadable-<timestamp>`, never deleted.
- Vault key: login keychain, generic password, service `com.cwland.TermiusReimagined`,
  account `local-vault-key`, not synchronized.

The app is ad-hoc signed, so the first launch after each rebuild may ask for access to the
vault key in your keychain: click "Always Allow".
