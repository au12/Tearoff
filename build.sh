#!/bin/bash
# Builds build/Tearoff.app (Apple Silicon). Needs Xcode or the Command Line Tools.
#   Contents/MacOS/Tearoff            the app
#   Contents/Helpers/tearoff          command-line tool
#   Contents/Helpers/tearoff-filter   CUPS filter (copied to /Library/Printers/Tearoff by the driver installer)
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-arm64}"
APP="build/Tearoff.app"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift not found. Install the Command Line Tools with:  xcode-select --install" >&2
  exit 1
fi

echo "→ Compiling ($ARCH)…"
swift build -c release --arch "$ARCH"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/TearoffApp" "$APP/Contents/MacOS/Tearoff"
cp "$BIN/tearoff" "$APP/Contents/Helpers/tearoff"
cp "$BIN/tearoff-filter" "$APP/Contents/Helpers/tearoff-filter"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Building icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad-hoc)…"
codesign --force --sign - --identifier com.au12.tearoff.cli "$APP/Contents/Helpers/tearoff"
codesign --force --sign - --identifier com.au12.tearoff.filter "$APP/Contents/Helpers/tearoff-filter"
codesign --force --sign - --identifier com.au12.tearoff "$APP"

echo "✓ Built $APP"
