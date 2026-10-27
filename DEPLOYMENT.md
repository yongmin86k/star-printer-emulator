# Deployment

There are two ways to ship the app:

| Channel | Who installs it | How | Signed with |
| --- | --- | --- | --- |
| **TestFlight → Mac App Store** | Testers through the TestFlight app, then the public through the Mac App Store | Archive in Xcode and upload to App Store Connect | Apple Distribution (Xcode handles it) |
| **Developer ID DMG** | Anyone you send the `.dmg` to | `scripts/release.sh` | Developer ID Application + notarization |

TestFlight works on macOS the same way it does on iOS. Testers install the **TestFlight** app from the Mac App Store and install your build from there.

## XcodeGen

[XcodeGen](https://github.com/yonaskolb/XcodeGen) generates `StarEmu.xcodeproj` from `project.yml`. `project.yml` is the source of truth. The generated project is committed too, so you can open it without installing anything.

### Install

```bash
brew install xcodegen          # Homebrew (recommended)
mint install yonaskolb/XcodeGen  # or Mint
xcodegen --version             # check
```

Without Homebrew or Mint, build it from source (needs Xcode):

```bash
git clone https://github.com/yonaskolb/XcodeGen.git
cd XcodeGen && make install
```

### Use

Run XcodeGen from the repo root:

```bash
xcodegen generate              # rewrites StarEmu.xcodeproj from project.yml
open StarEmu.xcodeproj
```

Regenerate when you:

- edit `project.yml` (versions, build settings, entitlements, targets);
- add, remove or rename files under `App/` or `Config/`;
- pull changes where `project.yml` changed but `StarEmu.xcodeproj` didn't.

Rules:

- **Don't hand-edit project settings in Xcode.** The next `xcodegen generate` overwrites them. Make the change in `project.yml` and regenerate.
- **Commit `project.yml` and `StarEmu.xcodeproj` together**, so the two never drift apart.
- `scripts/release.sh` runs `xcodegen generate` itself. If `git status` shows `StarEmu.xcodeproj` changed after a release build, commit it.

## Signing setup (once per machine)

Your bundle ID and team ID never go into the repo. `project.pbxproj` is committed, so both live in xcconfig files instead:

- `Config/Signing.xcconfig` (committed): the defaults. It uses ad-hoc signing and a placeholder bundle ID (`dev.staremu.StarEmu`), so a fresh clone builds without an Apple account.
- `Config/Local.xcconfig` (git-ignored): your real bundle ID, team and signing identity. `Signing.xcconfig` includes it when the file exists, and its values win.

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
# edit PRODUCT_BUNDLE_IDENTIFIER and DEVELOPMENT_TEAM (developer.apple.com > Account > Membership details)
```

Check it took effect:

```bash
xcodebuild -project StarEmu.xcodeproj -scheme StarEmu -showBuildSettings | grep -E " (PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY) ="
```

> **Don't pick a Team or edit the Bundle Identifier in Xcode's Signing & Capabilities / General tabs.** That writes the value into `project.pbxproj`. It then overrides `Local.xcconfig` and gets committed. Change them in `Local.xcconfig` instead. Xcode still shows both, read from the xcconfig. Before you commit, this should print nothing:
>
> ```bash
> grep -n -E "PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|/Users/" StarEmu.xcodeproj/project.pbxproj
> ```

## TestFlight / Mac App Store

### One-time setup

1. **Apple Developer Program** membership for the team in `Local.xcconfig`.
2. **App ID.** Pick your real bundle ID and put it in `Local.xcconfig` *before* creating the app record. Once a build is uploaded, the app is tied to that ID for good. Automatic signing registers it on the first archive. You can also add it yourself under Certificates, Identifiers & Profiles > Identifiers.
3. **App record.** In [App Store Connect](https://appstoreconnect.apple.com), go to Apps > + > New App:
   - Platform: macOS
   - Bundle ID: the `PRODUCT_BUNDLE_IDENTIFIER` from your `Local.xcconfig`
   - SKU: any unique string, e.g. `staremu-mac`
4. **Requirements the project already meets:**
   - App Sandbox is on (`App/StarEmu.entitlements`).
   - The category is set (`LSApplicationCategoryType`).
   - The icon comes from `App/Assets.xcassets`.
5. **Export compliance (optional).** Every upload asks whether the app uses encryption. If your answer is "no" (the emulator uses plain TCP and no TLS), you can stop the prompt by adding this under `settings.base` in `project.yml`:
   ```yaml
   INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
   ```

### Each release

1. **Bump versions** in `project.yml`:
   - `MARKETING_VERSION`: the user-facing version, e.g. `0.2.0`.
   - `CURRENT_PROJECT_VERSION`: the build number. It **must increase on every upload**, even when the marketing version stays the same.

   Then run `xcodegen generate` and commit `project.yml` together with `StarEmu.xcodeproj`.
2. **Archive.** Open `StarEmu.xcodeproj`. Select the scheme **StarEmu** and the destination **Any Mac**, then choose **Product > Archive**.
3. **Upload.** In the Organizer that opens, select the archive and choose **Distribute App > App Store Connect > Upload**. Keep the defaults, which use automatic signing with Apple Distribution.
4. **TestFlight.** In App Store Connect, open the app's TestFlight tab:
   - Wait for the build to finish processing, usually 5–30 minutes. Answer export compliance if Xcode asks.
   - **Internal testers** (up to 100 members of your App Store Connect team) get the build right away, with no review.
   - **External testers** (by email or a public link) need a short Beta App Review for the first build of each version.
5. **App Store (when ready).** Go to the App Store tab, create a version, pick the tested build, fill in the listing and submit it for review.

### From the command line (optional)

This is the same flow without the Xcode UI. Write the export options to a temp file so nothing team-specific lands in the repo:

```bash
VERSION=0.2.0 BUILD=2
ARCHIVE=build/StarEmu.xcarchive
OPTS=$(mktemp -t ExportOptions).plist
cat > "$OPTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF

xcodegen generate
xcodebuild -project StarEmu.xcodeproj -scheme StarEmu -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTS" -allowProvisioningUpdates
```

The upload signs in with the Apple account added under Xcode > Settings > Accounts. On CI, use an App Store Connect API key instead by adding `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID` to both `xcodebuild` calls. On CI, also pass `PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID DEVELOPMENT_TEAM=$TEAM_ID` (from CI secrets) instead of using `Local.xcconfig`.

## Developer ID DMG (outside the App Store)

This is for handing the app and the `staremu` CLI to people directly. It needs a **Developer ID Application** certificate. Create one under Xcode > Settings > Accounts > Manage Certificates.

Create a notarization keychain profile once:

```bash
xcrun notarytool store-credentials staremu --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
```

Then build, sign, notarize and staple:

```bash
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=staremu scripts/release.sh 0.2.0
```

The output goes to `build/release/<version>/`. If you leave out both variables, you get an ad-hoc build for local use only, and Gatekeeper blocks it on other Macs.
