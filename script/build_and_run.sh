#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SSHAutoTunnel"
BUNDLE_ID="dev.clange.ssh-autotunnel"
MIN_SYSTEM_VERSION="26.0"
APP_VERSION="0.7.0"
APP_BUILD="10"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/sparkle.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_HELPER="$APP_HELPERS/ssh-autotunnelctl"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

wait_for_app_exit() {
  local timeout_seconds="${1:-10}"
  local deadline=$((SECONDS + timeout_seconds))
  while pgrep -x "$APP_NAME" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done
}

quit_existing_app() {
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return
  fi

  echo "Requesting $APP_NAME to quit..."
  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  if wait_for_app_exit 12; then
    return
  fi

  if [[ "${FORCE_QUIT_EXISTING_APP:-0}" == "1" ]]; then
    echo "$APP_NAME did not quit gracefully; FORCE_QUIT_EXISTING_APP=1 is set, sending SIGKILL." >&2
    pkill -KILL -x "$APP_NAME" >/dev/null 2>&1 || true
    wait_for_app_exit 3 || true
    return
  fi

  echo "$APP_NAME did not quit gracefully. Refusing to force-kill because that can orphan SSH tunnels." >&2
  echo "Close the app manually, or rerun with FORCE_QUIT_EXISTING_APP=1 if you accept that risk." >&2
  exit 1
}

quit_existing_app

swift build --product "$APP_NAME"
swift build --product ssh-autotunnelctl
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
BUILD_CLI="$(swift build --show-bin-path)/ssh-autotunnelctl"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI" "$CLI_HELPER"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Resources/AppIconDark.icns" "$APP_RESOURCES/AppIconDark.icns"
chmod +x "$APP_BINARY" "$CLI_HELPER"

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

embed_sparkle "$APP_BUNDLE" false

if [[ "${SKIP_CODESIGN:-0}" != "1" ]]; then
  sign_sparkle "$APP_BUNDLE" "$CODESIGN_IDENTITY" local
  /usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" "$CLI_HELPER"
  /usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
