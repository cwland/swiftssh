# SwiftSSH

Formerly "Termius Reimagined" (renamed in v0.11.0; the first launch moves your vault over, see [App/README.md](App/README.md#moving-over-from-termius-reimagined-first-launch)).

A native macOS SSH client and terminal emulator inspired by the design and workflow of Termius.

- **Platform:** macOS 15+ (Swift, SwiftUI, AppKit bridging)
- **Core:** shared `CoreSSH` Swift package (SSH/SFTP engine, data models, iCloud sync) for a future iOS/iPadOS companion
- **Key libraries:** SwiftTerm, Citadel (swift-nio-ssh), SwiftData + CloudKit, iCloud Keychain

See the full [project specification](docs/SPEC.md).

**Terminal themes:** Settings → Terminal has a theme gallery (Automatic, SwiftSSH Light/Dark and 18 bundled themes) and the text size (⌘= / ⌘− / ⌘0). Hosts and groups can have their own theme, which syncs to every Mac; open tabs update live.

**Third-party themes:** Bundled terminal themes are MIT-licensed by their authors; see `Packages/CoreSSH/Sources/AppCore/Resources/terminal-themes-notices.txt` (also in Settings → Terminal → Theme credits).

## Building the Mac app

The Xcode project is generated from `App/project.yml` with XcodeGen (it is not committed):

```
brew install xcodegen
cd App && xcodegen generate
xcodebuild -project SwiftSSH.xcodeproj -scheme SwiftSSH -destination 'platform=macOS' test
open SwiftSSH.xcodeproj   # then Run (Cmd+R)
```

See [App/README.md](App/README.md) for details.

Self-hosting the sync server: see [Server/README.md](Server/README.md).
