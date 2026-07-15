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

`package_release.sh` signs the app bundle, embedded CLI helper, and top-level CLI with hardened runtime and a secure timestamp, then creates `dist/release/SSH-AutoTunnel-<version>.dmg`.

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

## GitHub Release

Create a draft release after notarization passes:

```sh
gh release create "v0.6.2" \
  dist/release/SSH-AutoTunnel-0.6.2.dmg \
  dist/release/SSH-AutoTunnel-0.6.2.dmg.sha256 \
  --draft \
  --title "SSH AutoTunnel 0.6.2" \
  --notes "Developer ID-signed and notarized macOS build."
```

Before publishing, download the draft asset on a separate macOS account or machine and confirm Gatekeeper opens the DMG and launches the app normally.
