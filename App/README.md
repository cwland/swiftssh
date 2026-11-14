# Termius Reimagined — Mac app

SwiftUI app target for macOS 15+. All logic lives in the `CoreSSH` package
(`../Packages/CoreSSH`, products `AppCore`, `CoreModels`, `SyncCore`, `SSHCore`); this folder
holds only the window, views and platform glue (Keychain, the SwiftTerm terminal view).

The Xcode project is generated from `project.yml` and is not committed.

## Build, test and run

```
brew install xcodegen
cd App && xcodegen generate
xcodebuild -project TermiusReimagined.xcodeproj -scheme TermiusReimagined -destination 'platform=macOS' -skipPackagePluginValidation test
open TermiusReimagined.xcodeproj   # then Run (Cmd+R)
```

The terminal view comes from [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), whose
package runs a small build-tool plugin (`SwiftTermBuildInfoPlugin`, it writes version info).
Xcode asks once to "Trust & Enable" it; on the command line pass `-skipPackagePluginValidation`.

If the test target fails with a "missing required module" (or "no such module 'AppCore'")
error, add the `AppCore` and `SyncCore` package products to the `TermiusReimaginedTests`
dependencies in `project.yml` and regenerate.

When the app runs as the unit-test host it skips loading the vault and Keychain key, so tests
never touch your real vault.

Re-run `xcodegen generate` whenever files are added or removed under `Sources/` or `Tests/`.

## Where things are stored

- Vault: `~/Library/Application Support/TermiusReimagined/vault.bin` (AES-256-GCM).
  A vault that cannot be read is renamed to `vault.bin.unreadable-<timestamp>`, never deleted.
- Vault key: login keychain, generic password, service `com.cwland.TermiusReimagined`,
  account `local-vault-key`, not synchronized.

## OS icons (Settings → OS Icons)

Host badges show a generic symbol per OS. Open **Settings** (Cmd+,) → **OS Icons** to customize
each OS: **Choose Image…** (SVG, PNG, JPEG or PDF), **From URL…** (http/https only, up to 2 MB,
15 s timeout), a badge **color**, **Show in white** (on: the image is drawn as a white
silhouette, so it needs a transparent background; off: it keeps its own colors) and **Reset**
(standard symbol, color and white drawing; the logo file goes to the Trash). Every badge in the
app updates immediately.

Chosen images are only decoded as images and redrawn as a 256×256-pixel PNG (128 pt at 2x,
transparent, aspect-fitted inside a 12% margin). Everything is stored on this Mac only, in
`~/Library/Application Support/TermiusReimagined/Badges/` (the app creates the folder at
launch; **Show in Finder** at the bottom of the pane opens it):

- `<name>.png` / `<name>.svg` — the logo (SVG is used when both exist; choosing an image in
  Settings writes `<name>.png` and removes `<name>.svg`).
- `settings.json` — per-OS "show in white" and color, keyed by `<name>`; only changed OSes are
  listed. Not synced.

You can still drop `<name>.svg` or `<name>.png` files into the folder by hand; they are read at
launch and whenever the OS Icons pane opens.

| OS | File name |
| --- | --- |
| Ubuntu | `ubuntu` |
| Debian | `debian` |
| Raspberry Pi OS | `raspberry-pi` |
| Fedora | `fedora` |
| RHEL / CentOS / Rocky / Alma | `rhel` |
| Alpine | `alpine` |
| Arch | `arch` |
| macOS | `macos` |
| FreeBSD | `freebsd` |
| Other Linux | `linux` |
| Synology DSM | `synology` |
| Home Assistant OS | `home-assistant` |

The repository ships no logo files.

The app is ad-hoc signed, so the first launch after each rebuild may ask for access to the
vault key in your keychain: click "Always Allow".
