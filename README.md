# Termius Reimagined

A native macOS SSH client and terminal emulator inspired by the design and workflow of Termius.

- **Platform:** macOS 14+ (Swift, SwiftUI, AppKit bridging)
- **Core:** shared `CoreSSH` Swift package (SSH/SFTP engine, data models, iCloud sync) for a future iOS/iPadOS companion
- **Key libraries:** SwiftTerm, Citadel (swift-nio-ssh), SwiftData + CloudKit, iCloud Keychain

See the full [project specification](docs/SPEC.md).

## Building the Mac app

The Xcode project is generated from `App/project.yml` with XcodeGen (it is not committed):

```
brew install xcodegen
cd App && xcodegen generate
xcodebuild -project TermiusReimagined.xcodeproj -scheme TermiusReimagined -destination 'platform=macOS' test
open TermiusReimagined.xcodeproj   # then Run (Cmd+R)
```

See [App/README.md](App/README.md) for details.

Self-hosting the sync server: see [Server/README.md](Server/README.md).
