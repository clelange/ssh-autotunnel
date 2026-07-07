#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SSHAutoTunnel"
CLI_NAME="ssh-autotunnelctl"
BUNDLE_ID="dev.clange.ssh-autotunnel"
MIN_SYSTEM_VERSION="26.0"
APP_VERSION="${APP_VERSION:-0.2.0}"
APP_BUILD="${APP_BUILD:-2}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/release"
STAGE_DIR="$DIST_DIR/stage"
PAYLOAD_DIR="$STAGE_DIR/SSH AutoTunnel"
APP_BUNDLE="$PAYLOAD_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_HELPER="$APP_HELPERS/$CLI_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DMG_PATH="$DIST_DIR/SSH-AutoTunnel-$APP_VERSION.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
NOTARY_LOG_PATH="$DIST_DIR/notarytool-submit.json"

MODE="${1:-package}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
CODESIGN_ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARIZE="${NOTARIZE:-0}"

case "$MODE" in
  package|--package)
    ;;
  verify|--verify)
    ;;
  notarize|--notarize)
    NOTARIZE=1
    ;;
  *)
    echo "usage: $0 [package|--package|verify|--verify|notarize|--notarize]" >&2
    exit 2
    ;;
esac

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool not found: $1" >&2
    exit 1
  fi
}

select_codesign_identity() {
  if [[ -n "$CODESIGN_IDENTITY" ]]; then
    return
  fi

  local identity_hashes
  identity_hashes="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Developer ID Application:/ {print $2}')"

  local identity_count
  identity_count="$(printf "%s\n" "$identity_hashes" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

  if [[ "$identity_count" == "1" ]]; then
    CODESIGN_IDENTITY="$(printf "%s\n" "$identity_hashes" | /usr/bin/sed '/^$/d' | /usr/bin/head -n 1)"
    return
  fi

  if [[ "$identity_count" == "0" ]]; then
    echo "error: no Developer ID Application signing identity found in Keychain" >&2
  else
    echo "error: multiple Developer ID Application identities found; set CODESIGN_IDENTITY to one SHA-1 hash" >&2
  fi

  /usr/bin/security find-identity -v -p codesigning >&2
  exit 1
}

sign_code() {
  local path="$1"
  local codesign_args=(--force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp)

  if [[ -n "$CODESIGN_ENTITLEMENTS" ]]; then
    codesign_args+=(--entitlements "$CODESIGN_ENTITLEMENTS")
  fi

  /usr/bin/codesign "${codesign_args[@]}" "$path"
}

sign_disk_image() {
  /usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
  /usr/bin/codesign --verify --strict "$DMG_PATH"
}

notary_submit_args() {
  if [[ -n "$NOTARY_PROFILE" ]]; then
    printf '%s\0' --keychain-profile "$NOTARY_PROFILE"
    return
  fi

  if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    printf '%s\0' --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"
    return
  fi

  echo "error: notarization needs NOTARY_PROFILE or NOTARY_APPLE_ID, NOTARY_TEAM_ID, and NOTARY_PASSWORD" >&2
  exit 1
}

notarize_and_staple() {
  local notary_auth=()
  while IFS= read -r -d '' arg; do
    notary_auth+=("$arg")
  done < <(notary_submit_args)

  /usr/bin/xcrun notarytool submit "$DMG_PATH" "${notary_auth[@]}" --wait --output-format json | /usr/bin/tee "$NOTARY_LOG_PATH"

  if ! /usr/bin/grep -q '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$NOTARY_LOG_PATH"; then
    echo "error: notarization did not finish with status Accepted; see $NOTARY_LOG_PATH" >&2
    exit 1
  fi

  /usr/bin/xcrun stapler staple "$DMG_PATH"
  /usr/bin/xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl -a -vvv -t open --context context:primary-signature --ignore-cache "$DMG_PATH"
}

require_tool swift
require_tool hdiutil
require_tool shasum

select_codesign_identity

cd "$ROOT_DIR"

swift build -c release --product "$APP_NAME"
swift build -c release --product "$CLI_NAME"

BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$STAGE_DIR" "$DMG_PATH" "$CHECKSUM_PATH" "$NOTARY_LOG_PATH"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"

cp "$BIN_DIR/$APP_NAME" "$APP_BINARY"
cp "$BIN_DIR/$CLI_NAME" "$PAYLOAD_DIR/$CLI_NAME"
cp "$BIN_DIR/$CLI_NAME" "$CLI_HELPER"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Resources/AppIconDark.icns" "$APP_RESOURCES/AppIconDark.icns"
chmod +x "$APP_BINARY" "$PAYLOAD_DIR/$CLI_NAME" "$CLI_HELPER"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>SSH AutoTunnel</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>SSH AutoTunnel opens interactive SSH sessions in the terminal app you select.</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

sign_code "$PAYLOAD_DIR/$CLI_NAME"
/usr/bin/codesign --verify --strict "$PAYLOAD_DIR/$CLI_NAME"
sign_code "$CLI_HELPER"
/usr/bin/codesign --verify --strict "$CLI_HELPER"
sign_code "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

/usr/bin/hdiutil create -volname "SSH AutoTunnel" -srcfolder "$PAYLOAD_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
sign_disk_image

if [[ "$NOTARIZE" == "1" ]]; then
  notarize_and_staple
else
  echo "Skipping notarization. Re-run with NOTARY_PROFILE=<profile> $0 --notarize for a Gatekeeper-ready release." >&2
fi

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" >"$(basename "$CHECKSUM_PATH")"
)

case "$MODE" in
  package|--package|notarize|--notarize)
    echo "$DMG_PATH"
    ;;
  verify|--verify)
    test -d "$APP_BUNDLE"
    test -x "$APP_BINARY"
    test -x "$CLI_HELPER"
    test -x "$PAYLOAD_DIR/$CLI_NAME"
    test -f "$DMG_PATH"
    test -f "$CHECKSUM_PATH"
    (cd "$DIST_DIR" && /usr/bin/shasum -a 256 -c "$(basename "$CHECKSUM_PATH")")
    /usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST" | /usr/bin/grep -qx "$BUNDLE_ID"
    codesign_details="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
    if [[ "$codesign_details" != *"flags="*"runtime"* ]]; then
      echo "error: hardened runtime flag missing from app signature" >&2
      exit 1
    fi
    echo "$DMG_PATH"
    ;;
esac
