#!/usr/bin/env bash
# Compile and run the AppModel concurrency tests.
#
# SwiftPM cannot help here: the app target is an executable, so a test target cannot import
# it. Same approach as build-app.sh — compile the sources directly.
#
#   apps/macos/scripts/test-races.sh
#
# Requires Xcode (not just Command Line Tools) for the SwiftUI macros:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer apps/macos/scripts/test-races.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${TMPDIR:-/tmp}/drivedrop-racetests"
mkdir -p "$out"

# Everything except the views. This used to be an explicit list, which meant a new
# non-UI file silently stayed out of the test build and failed with
# "cannot find 'X' in scope" only when something referenced it.
ui=(DriveDropApp.swift ContentView.swift MenuBar.swift SettingsView.swift Glass.swift)
srcs=()
for f in "$here"/Sources/DriveDrop/*.swift; do
  base="$(basename "$f")"
  skip=0
  for u in "${ui[@]}"; do [[ "$base" == "$u" ]] && skip=1; done
  [[ $skip -eq 0 ]] && srcs+=("$f")
done
srcs+=("$here"/Tests/RaceTests/main.swift)

echo "compiling…"
swiftc -O "${srcs[@]}" -o "$out/run"
echo "running…"
"$out/run"
