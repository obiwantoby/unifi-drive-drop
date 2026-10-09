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

srcs=(
  "$here"/Sources/DriveDrop/Models.swift
  "$here"/Sources/DriveDrop/DriveSession.swift
  "$here"/Sources/DriveDrop/LiveDriveClient.swift
  "$here"/Sources/DriveDrop/CRC32.swift
  "$here"/Sources/DriveDrop/MockDriveClient.swift
  "$here"/Sources/DriveDrop/AppModel.swift
  "$here"/Tests/RaceTests/main.swift
)

echo "compiling…"
swiftc -O "${srcs[@]}" -o "$out/run"
echo "running…"
"$out/run"
