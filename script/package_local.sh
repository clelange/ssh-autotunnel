#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SSHAutoTunnel"
CLI_NAME="ssh-autotunnelctl"
BUNDLE_ID="dev.clange.ssh-autotunnel"
MIN_SYSTEM_VERSION="26.0"
APP_VERSION="0.5.0"
APP_BUILD="5"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/package"
ARCHIVE_ROOT="$DIST_DIR/SSH AutoTunnel"
APP_BUNDLE="$ARCHIVE_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_HELPER="$APP_HELPERS/$CLI_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ZIP_PATH="$DIST_DIR/SSH-AutoTunnel-local.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

MODE="${1:-package}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "$ROOT_DIR"

swift build -c release --product "$APP_NAME"
swift build -c release --product "$CLI_NAME"

BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$ARCHIVE_ROOT" "$ZIP_PATH" "$CHECKSUM_PATH"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"

cp "$BIN_DIR/$APP_NAME" "$APP_BINARY"
cp "$BIN_DIR/$CLI_NAME" "$ARCHIVE_ROOT/$CLI_NAME"
cp "$BIN_DIR/$CLI_NAME" "$CLI_HELPER"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Resources/AppIconDark.icns" "$APP_RESOURCES/AppIconDark.icns"
chmod +x "$APP_BINARY" "$ARCHIVE_ROOT/$CLI_NAME" "$CLI_HELPER"

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

if [[ "${SKIP_CODESIGN:-0}" != "1" ]]; then
  /usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" "$ARCHIVE_ROOT/$CLI_NAME"
  /usr/bin/codesign --verify --strict "$ARCHIVE_ROOT/$CLI_NAME"
  /usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" "$CLI_HELPER"
  /usr/bin/codesign --verify --strict "$CLI_HELPER"
  /usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
fi

(
  cd "$DIST_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "SSH AutoTunnel" "$ZIP_PATH"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" >"$(basename "$CHECKSUM_PATH")"
)

case "$MODE" in
  package|--package)
    echo "$ZIP_PATH"
    ;;
  verify|--verify)
    test -d "$APP_BUNDLE"
    test -x "$APP_BINARY"
    test -x "$CLI_HELPER"
    test -x "$ARCHIVE_ROOT/$CLI_NAME"
    test -f "$ZIP_PATH"
    test -f "$CHECKSUM_PATH"
    (cd "$DIST_DIR" && /usr/bin/shasum -a 256 -c "$(basename "$CHECKSUM_PATH")")
    /usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST" | grep -qx "$BUNDLE_ID"
    echo "$ZIP_PATH"
    ;;
  *)
    echo "usage: $0 [package|--package|verify|--verify]" >&2
    exit 2
    ;;
esac
