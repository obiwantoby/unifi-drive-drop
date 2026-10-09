#!/bin/bash
# Build a distributable DriveDrop.app, then wrap it in a .dmg and a .zip.
#
#   ./scripts/make_release.sh            -> dist/DriveDrop-<version>.{dmg,zip} + SHA256SUMS
#
# READ THIS BEFORE SHIPPING TO ANYONE ELSE
# ---------------------------------------
# The bundle is signed **ad-hoc** (`codesign -s -`). That is enough to run locally, but it
# is not a Developer ID signature and the build is not notarized, so Gatekeeper will refuse
# it on someone else's Mac with:
#
#   "DriveDrop" can't be opened because Apple cannot check it for malicious software.
#
# There are only two ways past that:
#   1. the user right-clicks the app and chooses Open (once), or runs
#        xattr -dr com.apple.quarantine /Applications/DriveDrop.app
#   2. you sign with an Apple Developer ID and notarize (see the end of this file).
#
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Read the version from VERSION, not from a previously built bundle: that ships a new
# binary under an old version string the moment someone forgets to rebuild first.
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
NAME="DriveDrop-$VERSION"
OUT=dist
ROOT="$(pwd)"
APP="$OUT/$NAME/DriveDrop.app"

echo "==> building universal release (arm64 + x86_64)"
# Both --arch flags make SwiftPM produce a fat binary; -Xswiftc -target does not, it leaves
# arm64 object files in the link line and the link fails.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DriveDrop"
lipo -info "$BIN"

echo "==> assembling bundle"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DriveDrop"
[[ -f resources/AppIcon.icns ]] || {
  swift scripts/make_icon.swift resources/AppIcon.iconset >/dev/null
  iconutil -c icns resources/AppIcon.iconset -o resources/AppIcon.icns
}
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>DriveDrop</string>
  <key>CFBundleDisplayName</key>       <string>DriveDrop</string>
  <key>CFBundleIdentifier</key>        <string>com.drivedrop.macos</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>DriveDrop</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key>   <string>DriveDrop. Unofficial UniFi Drive client.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing ad-hoc"
# --deep is fine for a hand-assembled bundle with no nested code. A hardened-runtime +
# Developer ID build must instead sign each nested item inside-out.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "==> packaging"
ln -sf /Applications "$OUT/$NAME/Applications"
hdiutil create -quiet -volname DriveDrop -srcfolder "$OUT/$NAME" -ov -format UDZO "$OUT/$NAME.dmg"
# Zip the bundle itself so people who prefer `unzip` get a working .app.
(cd "$OUT/$NAME" && zip -qry "$ROOT/$OUT/$NAME.zip" DriveDrop.app)

echo "==> checksums"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS && cat SHA256SUMS)

ls -la "$OUT" | awk 'NR>2 {printf "  %8d  %s\n", $5, $9}'

cat <<'NOTE'

Gatekeeper: this build is ad-hoc signed and NOT notarized. Recipients must right-click ->
Open the first time, or clear quarantine. To remove that step you need an Apple Developer
ID ($99/yr), then:

  codesign --force --deep --options runtime \
    --sign "Developer ID Application: Your Name (TEAMID)" DriveDrop.app
  xcrun notarytool submit DriveDrop.dmg --keychain-profile prof --wait
  xcrun stapler staple DriveDrop.dmg

Notarization also requires the app to survive the hardened runtime, which means the Keychain
access and the drag-and-drop pasteboard have to be re-tested under it.
NOTE
