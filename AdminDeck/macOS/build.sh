#!/usr/bin/env bash
# Build AdminDeck.app (no Xcode project needed). Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"

APP=build/AdminDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

# Shared PowerShell catalog code (same as the Windows app) + where this repo lives.
cp ../AdminDeck.Catalog.psm1 ../Export-AdCatalog.ps1 "$APP/Contents/Resources/"
printf '%s\n' "$REPO" > "$APP/Contents/Resources/repo-root.txt"

FLAGS=(-O -parse-as-library -swift-version 5)
swiftc "${FLAGS[@]}" -target arm64-apple-macos14.4 -o build/AdminDeck-arm64 Sources/AdminDeck.swift
swiftc "${FLAGS[@]}" -target x86_64-apple-macos14.4 -o build/AdminDeck-x86_64 Sources/AdminDeck.swift
lipo -create build/AdminDeck-arm64 build/AdminDeck-x86_64 -output "$APP/Contents/MacOS/AdminDeck"
rm build/AdminDeck-arm64 build/AdminDeck-x86_64

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x AdminDeck 2>/dev/null || true
  rm -rf /Applications/AdminDeck.app
  cp -R "$APP" /Applications/
  open /Applications/AdminDeck.app
  echo "Installed to /Applications and launched"
fi
