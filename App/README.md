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

Re-run `xcodegen generate` whenever files are added or removed under `Sources/` or `Tests/`.

## Where things are stored

- Vault: `~/Library/Application Support/TermiusReimagined/vault.bin` (AES-256-GCM).
  A vault that cannot be read is renamed to `vault.bin.unreadable-<timestamp>`, never deleted.
- Vault key: login keychain, generic password, service `com.cwland.TermiusReimagined`,
  account `local-vault-key`, not synchronized.

The app is ad-hoc signed, so after a rebuild macOS may ask for permission to read the
vault key from the keychain; choose "Always Allow".
