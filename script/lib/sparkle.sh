# Shared by the SwiftPM app packagers. ROOT_DIR must be set by the caller.
SPARKLE_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"

embed_sparkle() {
  local app_bundle="$1"
  local updates_enabled="$2"
  /bin/mkdir -p "$app_bundle/Contents/Frameworks"
  /usr/bin/ditto "$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$app_bundle/Contents/Frameworks/Sparkle.framework"
  /bin/cp "$SPARKLE_DIR/LICENSE" "$app_bundle/Contents/Resources/Sparkle-LICENSE.txt"
  /usr/bin/python3 - "$ROOT_DIR/Resources/Updater.plist" "$app_bundle/Contents/Info.plist" "$updates_enabled" <<'PY'
import plistlib
import sys
from pathlib import Path
settings, destination = map(Path, sys.argv[1:3])
info = plistlib.loads(destination.read_bytes())
info.update(plistlib.loads(settings.read_bytes()))
info['SSHAutoTunnelUpdatesEnabled'] = sys.argv[3] == 'true'
destination.write_bytes(plistlib.dumps(info))
PY
}

sign_sparkle() {
  local app_bundle="$1"
  local identity="$2"
  local mode="$3"
  local framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
  local args=(--force --sign "$identity" --preserve-metadata=entitlements)
  if [[ "$mode" == "release" ]]; then
    args+=(--options runtime --timestamp)
  fi
  # Sign nested code inside out. Keep Sparkle's own helper entitlements.
  local component
  for component in "$framework"/Versions/B/XPCServices/*.xpc \
    "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
    /usr/bin/codesign "${args[@]}" "$component"
  done
  /usr/bin/codesign --verify --deep --strict "$framework"
}
