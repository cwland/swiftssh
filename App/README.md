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

Every host has an OS from the **OS catalog** (Windows, macOS, Linux distributions, NAS systems,
routers and firewalls, hypervisors and containers, BSDs, Home Assistant). The OS is detected
when you connect (see below), or chosen in **Host Details → OS**. **Automatic** forgets a
chosen OS, so the next connection detects it again.

Open **Settings** (Cmd+,) → **OS Icons** to see the catalog grouped by category. Each row has:

- The **icon link**, prefilled with the catalog's default. Editing it (Return, or leaving the
  field) saves the link and downloads it at once. If that fails, the previous icon stays and the
  error shows on the row.
- **Download**, which fetches the row's link.
- **Choose Image…** (SVG, PNG, JPEG or PDF).
- **Reset**, which brings back the standard symbol, color, white drawing and default link. The
  logo file goes to the Trash.
- **Show in white**. When on, the image is drawn as a white silhouette, so it needs a
  transparent background. When off, it keeps its own colors. This switch is only available once
  the OS has an image.
- The badge **color**.

**Download All Defaults** at the top downloads the default icon of every OS that has no image yet,
or whose image came from its default link. It runs four downloads at a time and can be stopped.
OSes with a custom link or a chosen image are left alone.

Icons are only downloaded when you click one of these buttons or edit a link, never at launch.
Downloads are http/https only, up to 2 MB, with a 15 s timeout. Every badge in the app (host
cards, tabs, Logs, Host Details) updates as soon as an icon or setting changes.

Images are only ever decoded as images, off the main thread:

- Bitmaps are decoded as a thumbnail of at most 1024 px, and anything announcing more than
  50 megapixels is refused.
- SVG and PDF are drawn as vectors.

Each image is then redrawn as a 256×256-pixel sRGB PNG (128 pt at 2x, transparent,
aspect-fitted inside a 12% margin). Everything is stored on this Mac only, in
`~/Library/Application Support/TermiusReimagined/Badges/`. The app creates the folder at launch,
and **Show in Finder** at the bottom of the pane opens it.

- `<id>.png` / `<id>.svg` holds the logo, where `<id>` is the catalog id (e.g. `ubuntu`,
  `raspbian`, `home-assistant`).
  - When both files exist, the newer one is used.
  - Installing an image writes `<id>.png` and removes `<id>.svg`.
  - Logos saved as `raspberry-pi.*` by earlier builds are renamed to `raspbian.*`.
- `settings.json` holds, per OS: "show in white", color, a custom link, and the link the current
  image was downloaded from. It is keyed by `<id>` and lists only changed OSes. It is not synced.
  Each field is read on its own, so one bad value doesn't drop the file.

You can still drop `<id>.svg` or `<id>.png` files into the folder by hand. They are read at
launch and whenever the OS Icons pane opens.

### The catalog file

The catalog ships inside the app. It is not downloaded and contains no images. It lives in
`Packages/CoreSSH/Sources/AppCore/Resources/`:

- **`os-catalog.json`**: Cory's list, kept verbatim. It is a JSON object of categories, each an
  array of `{ "id", "name", "icon" }`.
- **`os-catalog-app.json`**: the app's overlay. It holds:
  - the category order, titles and SF Symbols
  - `extraEntries` (entries that aren't in Cory's list; currently Home Assistant, under the
    "Home Automation" category)
  - per-id badge `color` and `symbol`
  - the grey fallback (`#5B6475`, `terminal`)

**To add an OS:**

1. Add `{ "id": "my-os", "name": "My OS", "icon": "https://…/my-os.svg" }` to a category in
   `os-catalog.json`. A new category key works too; it is listed after the known ones and its
   title is made from the key.
   - Ids are lowercase letters, digits and dashes, because they become file names. An entry with
     any other id, an id that is already used, or no name is skipped.
   - The `icon` link must be http(s).
2. Optionally give it a color and symbol under `entries` in `os-catalog-app.json`.
3. For automatic detection, map it in `OSDetector` (`osReleaseIDs`, `unameNames` or a marker
   check).
4. Run the CoreSSH tests. They check that every entry has a valid id, link and color.

Hosts keep their OS id as a string. An id that isn't in the catalog (for example, a removed
entry, or one written by a newer build) still loads and syncs unchanged, and is shown as the grey
generic badge.

### OS detection

On the first connection of each app session (and again whenever an automatic host has no OS), the
app runs one short, read-only command. It needs no sudo and writes nothing to stderr on POSIX
shells. The OS is decided in this order:

1. **Windows**. Under cmd.exe the probe only echoes `Windows_NT`; a read-only follow-up (`ver` and
   the registry's `InstallationType`) gives the build:
   - build 22000 or later → Windows (11 / Server)
   - earlier build → Windows 10
   - Server, any build → Windows
   - Git Bash, MSYS2 or Cygwin: the build is read from `uname`.
2. **Marker files**: TrueNAS (`/etc/version`, `midclt`), Synology (`/etc/synoinfo.conf`), QNAP
   (`/etc/config/uLinux.conf`), Unraid (`/etc/unraid-version`), OpenMediaVault
   (`/etc/openmediavault`), Proxmox VE (`/usr/bin/pveversion`), XCP-ng (`/etc/xcp-ng-release`),
   pfSense (`/etc/platform`), OPNsense (`/usr/local/opnsense`), umbrelOS (`/home/umbrel/umbrel`),
   CasaOS (`/etc/casaos`, `casaos`), Raspberry Pi OS (`/etc/rpi-issue`), and, only when none of
   the others matched, Docker (`/.dockerenv`).
3. **os-release `ID`**, then **`ID_LIKE`**.
4. **`uname -s`**: Darwin, FreeBSD, OpenBSD, NetBSD, VMkernel (ESXi), or Linux.

Devices without a POSIX shell are never detected and keep the OS you choose: MikroTik,
Ubiquiti, Cisco, Sophos, Fortinet, ASUSTOR, TerraMaster and Apple / Darwin.

The repository ships no logo files.

The app is ad-hoc signed, so the first launch after each rebuild may ask for access to the
vault key in your keychain: click "Always Allow".

## Keep macOS permissions across rebuilds (recommended)

By default each build is ad-hoc signed, so macOS treats every rebuild as a new app and forgets the
permissions you gave it (for example **Files & Folders → "Data shared by 1Password"**). Sign your builds
with your own free certificate once, and macOS keeps recognising the app:

1. Open **Keychain Access → Keychain Access menu → Certificate Assistant → Create a Certificate…**
2. Name: `Termius Reimagined Local` · Identity Type: **Self-Signed Root** · Certificate Type: **Code Signing** → **Create**.
3. In Terminal, from the repo folder:
   ```
   echo 'CODE_SIGN_IDENTITY = Termius Reimagined Local' > App/Config/Local.xcconfig
   ```
4. `cd App && xcodegen generate`, then build as usual. The first build may ask to use the key — click **Always Allow**.
5. Give the permissions one last time (Files & Folders → Termius Reimagined → "Data shared by 1Password"); they now stick.

`App/Config/Local.xcconfig` is ignored by git, so each Mac has its own.

## App icon

The icon lives in `Sources/Assets.xcassets/AppIcon.appiconset` (rendered from `Design/appicon-dark.svg`).
`Design/` also holds the light tile, the plain symbol and the menu-bar template as SVG masters.
