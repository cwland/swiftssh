# SwiftSSH for iPhone and iPad: TestFlight

The iOS app is built and uploaded to TestFlight by GitHub Actions (`.github/workflows/ios-release.yml`) when a tag `ios-v<version>` is pushed. Signing is managed by Apple ("cloud signing"): no certificate or provisioning profile is kept in the repository or on your Mac. Xcode creates the App Store profile and signs with the team's cloud-managed distribution certificate during the upload.

What it builds: Xcode project `SwiftSSHMobile` (from `App-iOS/project.yml`), bundle ID `com.cwland.SwiftSSH.mobile`, team `7C54KH5NDL`, one universal app for iPhone and iPad.

## One-time setup

### 1. Register the bundle ID

1. Open [developer.apple.com/account](https://developer.apple.com/account) → Certificates, Identifiers & Profiles → **Identifiers** → **+**.
2. Choose **App IDs**, then **App**.
3. Description: `SwiftSSH Mobile`. Bundle ID: **Explicit**, `com.cwland.SwiftSSH.mobile`.
4. Leave every capability off (the app needs none), then Continue and Register.

### 2. Create the app record in App Store Connect

1. Open [App Store Connect](https://appstoreconnect.apple.com) → **Apps** → **+** → **New App**.
2. Fill in:
   - Platforms: **iOS**.
   - Name: the App Store name must be unique across the whole store, and **"SwiftSSH" may already be taken**. If it is, use something like **"SwiftSSH Companion"** or **"SwiftSSH Mobile"**. This name only shows in App Store Connect and TestFlight; the name under the icon on your Home Screen stays "SwiftSSH" (it comes from the app itself).
   - Primary language: English (U.S.).
   - Bundle ID: `com.cwland.SwiftSSH.mobile` (the one from step 1).
   - SKU: anything unique to you, e.g. `swiftssh-mobile`.
   - User Access: Full Access.
3. Click Create. Nothing else in the record (screenshots, description, pricing) is needed for TestFlight.

### 3. Check the API key's role

The workflow signs and uploads with an App Store Connect API key. Cloud signing needs a key with the **Admin** role. A key with the Developer role can't get the cloud-managed distribution certificate (the upload fails with `FORBIDDEN`), and some people report App Manager isn't enough either.

1. In App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys**, find the key whose Key ID is in the `NOTARY_KEY_ID` secret, and look at its **Access** column.
2. **If it's Admin:** nothing to do. The workflow uses the `NOTARY_KEY_*` secrets.
3. **If it's anything else** (the Mac notarization key was made with the Developer role): a key's role can't be changed, so make a second key for TestFlight and keep the notary key as it is.
   1. Click **+**, name it `SwiftSSH TestFlight`, Access **Admin**, Generate.
   2. Download the `.p8` (it can be downloaded only once) and note its Key ID. The Issuer ID is shown above the list.
   3. Add three repository secrets. In Terminal, in your swiftssh folder (replace `AuthKey_XXXXXXXXXX.p8`, the Key ID and the Issuer ID with yours):

      ```
      base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_P8 --repo cwland/swiftssh
      gh secret set ASC_KEY_ID --repo cwland/swiftssh --body XXXXXXXXXX
      gh secret set ASC_ISSUER_ID --repo cwland/swiftssh --body 00000000-0000-0000-0000-000000000000
      ```

   4. Move the `.p8` somewhere safe (or delete it); GitHub keeps the copy the workflow needs.

   When the `ASC_KEY_*` secrets exist, the workflow uses them instead of the `NOTARY_KEY_*` ones.

### 4. Add yourself as an internal tester

1. In App Store Connect, open the app → **TestFlight**.
2. Under **Internal Testing**, click **+** to create a group, e.g. `Me`, with **Enable automatic distribution** on.
3. Add yourself. Internal testers must be users of the team in App Store Connect; as the account holder you already are.

With automatic distribution, every new build reaches the group as soon as App Store Connect has processed it. Internal builds need no Apple review.

### 5. Export compliance

Nothing to do: the app declares `ITSAppUsesNonExemptEncryption` = NO in its `Info.plist` (SSH uses only standard encryption), so App Store Connect doesn't ask about encryption for each build.

## Upload a build

The version in the tag must match `MARKETING_VERSION` in `App-iOS/project.yml` (1.0.0 now). In Terminal, in your swiftssh folder:

```
git fetch origin
git tag ios-v1.0.0 origin/ios
git push origin ios-v1.0.0
```

That tags the latest commit on the `ios` branch (once it's merged, use `origin/main`). Then watch it under Actions → **ios-release** on GitHub, or with:

```
gh run watch --repo cwland/swiftssh
```

The build number is the workflow's run number, so every upload is a new build. To upload another build of the same version, add a suffix after a dash, for example:

```
git tag ios-v1.0.0-2 origin/ios
git push origin ios-v1.0.0-2
```

For a new version, change `MARKETING_VERSION` in `App-iOS/project.yml` first, commit and push, then tag `ios-v<new version>`.

After the workflow is green, App Store Connect processes the build (usually 5 to 30 minutes) and emails you when it's ready.

## Install on iPhone and iPad

1. Install **TestFlight** from the App Store on the iPhone and on the iPad, and sign in with the same Apple Account as App Store Connect.
2. Open TestFlight. SwiftSSH appears once the build is processed (or tap the link in the invitation email). Tap **Install**. The same build installs on both devices.
3. Open SwiftSSH and join your sync server: its address, a **new API key for this device** (create it on the server as for a new Mac), and your vault passphrase.
4. New builds show up in TestFlight; tap **Update** (or turn on automatic updates in TestFlight).

A TestFlight build expires after 90 days; push a new tag before then.

## If the upload fails

The workflow prints the errors from Xcode and keeps `archive.log` and `export.log` as the **ios-release-logs** artifact.

- **`FORBIDDEN` or "certificate" errors during export:** the API key's role is too low; see step 3.
- **"No profiles" or "bundle identifier" errors:** the bundle ID isn't registered, or the app record doesn't exist yet; see steps 1 and 2.
- **"The bundle version must be higher" / "redundant binary upload":** that build number was already uploaded (a re-run of a run that already uploaded). Push a new tag instead of re-running.
- **Tag doesn't match MARKETING_VERSION:** the version in the tag (before any dash suffix) must equal `MARKETING_VERSION` in `App-iOS/project.yml`.
- **Archive errors:** the `ios` workflow makes the same archive on every push to `ios` (its `archive` job), so these normally show up there first.
