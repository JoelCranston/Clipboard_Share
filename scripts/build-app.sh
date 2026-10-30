#!/usr/bin/env bash
# Builds ClipShare.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClipShare"

APP="build/ClipShare.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClipShare"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS will run it locally and remember its permissions.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ClipShare 2>/dev/null || true
  rm -rf /Applications/ClipShare.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/ClipShare.app"
  open /Applications/ClipShare.app
fi
