#!/bin/bash
# Builds DriveDrop.app from the SwiftPM executable and drops it in ./build.
# Run from apps/macos. Uses the full Xcode toolchain (the Command Line Tools
# ship without the SwiftUI macro plugin, so plain `swift build` fails).
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d /Applications/Xcode.app ]]; then
  echo "error: Xcode.app not found. SwiftUI macros need it, not just CLT." >&2
  exit 1
fi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

CONFIG="${1:-release}"
APP="build/DriveDrop.app"

swift build -c "$CONFIG"

# SwiftPM's product dir varies by version; find the real one.
LOWER="$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
CAP="$(echo "${LOWER:0:1}" | tr '[:lower:]' '[:upper:]')${LOWER:1}"
BIN=""
for c in ".build/$LOWER/DriveDrop" \
         ".build/out/Products/$CAP/DriveDrop" \
         ".build/arm64-apple-macosx/$LOWER/DriveDrop" \
         ".build/$CAP/DriveDrop"; do
  [[ -f "$c" ]] && BIN="$c" && break
done
[[ -n "$BIN" ]] || { echo "error: built binary not found under .build" >&2; exit 1; }
echo "binary: $BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DriveDrop"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>DriveDrop</string>
  <key>CFBundleDisplayName</key>       <string>DriveDrop</string>
  <key>CFBundleIdentifier</key>        <string>com.drivedrop.macos</string>
  <key>CFBundleVersion</key>           <string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>DriveDrop</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the Keychain and drag/drop pasteboard work locally.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo
echo "built: $(pwd)/$APP"
echo "run:   open '$APP'"
