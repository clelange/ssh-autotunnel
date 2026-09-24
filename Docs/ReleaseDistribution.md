# Release Distribution

Use this checklist for GitHub Releases distribution outside the Mac App Store.

## Signing Identity

Developer ID signing needs a certificate and its matching private key in Keychain. A downloaded `.cer` alone is only the public certificate; import a `.p12` if the private key is missing.

List available signing identities:

```sh
security find-identity -v -p codesigning
```

If more than one `Developer ID Application` identity has the same display name, pass the SHA-1 hash instead of the name:

```sh
CODESIGN_IDENTITY="<Developer ID Application SHA-1>" ./script/package_release.sh --verify
```

`package_release.sh` signs the app bundle, embedded CLI helper, and Sparkle updater helpers with hardened runtime and a secure timestamp, then creates `dist/release/SSH-AutoTunnel-<version>.dmg`. The mounted DMG contains only `SSHAutoTunnel.app` and an `Applications` link. Users drag the app onto that link; no separate CLI file needs to be copied.

The app uses its embedded helper regardless of shell configuration. Users who want Terminal access can launch the installed app and choose **Settings → Local API → Command Line Tool → Install Command Line Tool…** to create `/usr/local/bin/ssh-autotunnelctl`.

## Notarization

Store Apple notary credentials once in Keychain:

```sh
xcrun notarytool store-credentials "ssh-autotunnel-notary" \
  --apple-id "<apple-id-email>" \
  --team-id "<team-id>" \
  --password "<app-specific-password>"
```

Build, notarize, staple, and verify the release DMG:

```sh
NOTARY_PROFILE="ssh-autotunnel-notary" \
CODESIGN_IDENTITY="<Developer ID Application SHA-1>" \
./script/package_release.sh --notarize
```

The script fails if Apple does not return `Accepted`, if stapling fails, or if Gatekeeper rejects the stapled DMG.

## Update Signing

Official releases use Sparkle 2 with a signed feed at:

`https://github.com/clelange/ssh-autotunnel/releases/latest/download/appcast.xml`

GitHub Releases hosts both the feed and DMG; no extra server, GitHub Pages site, GitHub API token, or runtime service is required. Apple signing and notarization still use Apple's services. The app requires valid Ed25519 signatures on both the feed and download before extraction, and Developer ID validation before installation. Automatic daily checks are opt-in, silent installation is disabled, and the normal quit confirmation protects active SSH connections when restarting.

The public update key is committed in `Resources/Updater.plist`. Its private key is in the release machine's login Keychain under the Sparkle account `dev.clange.ssh-autotunnel`. After `swift package resolve`, inspect the existing **public** key with:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.clange.ssh-autotunnel -p
```

Keep a secure backup of that private key before resetting the Keychain or moving release machines. Sparkle's `generate_keys -x <private-file>` and `-f <private-file>` support private-key transfer: use a protected location outside the repository and remove the export after securely storing/importing it. Never commit or upload that file. Do not generate a replacement key for an existing update channel; this app requires signed feeds without an unsigned fallback, so losing the key can require a manual upgrade to recover. See [Sparkle's signing documentation](https://sparkle-project.org/documentation/#3-segue-for-security-concerns).

`package_release.sh --notarize` generates `dist/release/appcast.xml` only after stapling the final DMG. It verifies the signing key, version/build, minimum macOS version, archive length, GitHub asset URL, and feed/download signatures. Non-notarized packaging does not produce a feed. The feed contains one full update; there are no separate delta or release-note assets. Do not edit the XML or modify the DMG after signing.

For each release, increment `APP_VERSION` and the monotonically increasing `APP_BUILD` in all three packaging/launch scripts. Sparkle compares the build number. Versions through 0.7.0 need one manual upgrade to the first updater-enabled release. Keep the first updater release's own entry in its feed so manual checks report that it is current.

## GitHub Release

Create a draft release after notarization passes:

```sh
# Replace these with the version/build being released.
RELEASE_VERSION="0.8.0"
gh release create "v$RELEASE_VERSION" \
  "dist/release/SSH-AutoTunnel-$RELEASE_VERSION.dmg" \
  "dist/release/SSH-AutoTunnel-$RELEASE_VERSION.dmg.sha256" \
  dist/release/appcast.xml \
  --draft \
  --title "SSH AutoTunnel $RELEASE_VERSION" \
  --notes "Developer ID-signed and notarized macOS build."
```

Before publishing, download the draft asset on a separate macOS account or machine and confirm Gatekeeper opens the DMG, the app can be dragged onto the Applications link and launched normally, and optional command-line tool installation works from Settings.

Upload all three assets while the release is still a draft, then publish it as the latest stable release. Every later stable release must include `appcast.xml`; otherwise existing apps will receive a missing-feed error. Prereleases are not part of this update channel. Keep releases public so clients do not need authentication.

After publishing, download `appcast.xml` via the stable `/releases/latest/download/appcast.xml` URL, compare it byte-for-byte with the signed local file, and check from an older updater-enabled build. Confirm the update appears, downloads, waits for installation approval, honors cancellation with active SSH connections, installs, and relaunches. Use an isolated account/configuration for this check. Local/ad-hoc builds have updates disabled.

For an unpublished packaging rehearsal, set `APP_VERSION`, `APP_BUILD`, and an absolute `RELEASE_DIST_DIR` to isolate the output from the real release artifacts. CI runs `python3 script/test_appcast.py` after local packaging; it uses a disposable key and exercises real feed/DMG signatures, tampering rejection, release URL/build validation, and disabled-development-build rejection.
