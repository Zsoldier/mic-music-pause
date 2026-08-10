#!/bin/bash
#
# Build, Developer ID sign, and notarize mic-music-pause.app, then package it as
# a tarball ready to attach to a GitHub release and reference from the formula.
#
# Prerequisites (one-time), only possible once your Apple Developer enrollment is
# ACTIVE and you have a "Developer ID Application" certificate in your keychain:
#
#   1. Confirm the signing identity is present:
#        security find-identity -v -p codesigning
#      You should see: "Developer ID Application: Your Name (TEAMID)"
#
#   2. Store notarization credentials once (creates a keychain profile):
#        xcrun notarytool store-credentials mmp-notary \
#          --apple-id "you@example.com" \
#          --team-id  "TEAMID" \
#          --password "app-specific-password"   # https://appleid.apple.com -> App-Specific Passwords
#
# Usage (local, keychain profile):
#   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="mmp-notary" \
#   ./scripts/build-signed-app.sh 0.4.0
#
# Usage (CI, direct credentials):
#   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_APPLE_ID="you@example.com" NOTARY_TEAM_ID="TEAMID" \
#   NOTARY_PASSWORD="app-specific-password" \
#   ./scripts/build-signed-app.sh 0.4.0
#
set -euo pipefail

VERSION="${1:?usage: build-signed-app.sh <version>}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP to your 'Developer ID Application: ...' identity}"

# Notarization credentials: either a stored keychain profile (local dev) OR
# direct Apple ID / team / app-specific password (CI). Build the notarytool args.
NOTARY_ARGS=()
if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
else
  : "${NOTARY_PROFILE:=mmp-notary}"
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi

WORK="$(mktemp -d)"
APP="$WORK/mic-music-pause.app"
OUT_DIR="$REPO_DIR/dist"
mkdir -p "$OUT_DIR"

echo "==> Compiling menu bar app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -o "$APP/Contents/MacOS/mic-music-pause-menubar" "$REPO_DIR/src/menubar.swift"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>mic-music-pause</string>
  <key>CFBundleDisplayName</key><string>mic-music-pause</string>
  <key>CFBundleIdentifier</key><string>com.zsoldier.mic-music-pause</string>
  <key>CFBundleExecutable</key><string>mic-music-pause-menubar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>mic-music-pause automatically pauses Apple Music when you join a call (Teams, Zoom, FaceTime, and similar) and resumes it when the call ends. To do that it needs permission to control the Music app: it only sends play and pause commands and reads whether Music is currently playing. It does not read your music library, files, messages, or any other personal data, and it never controls any other app.</string>
</dict>
</plist>
PLIST

echo "==> Codesigning (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp \
  --entitlements "$REPO_DIR/packaging/mic-music-pause.entitlements" \
  --sign "$DEVELOPER_ID_APP" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing (this can take a few minutes)"
ZIP="$WORK/mic-music-pause.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling and verifying"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP" || true

echo "==> Packaging tarball"
# Wrap the .app in a parent dir: Homebrew strips the single top-level directory
# when staging a resource, so without this it would land *inside* the bundle.
mkdir -p "$WORK/pkg"
mv "$APP" "$WORK/pkg/mic-music-pause.app"
TARBALL="$OUT_DIR/mic-music-pause-${VERSION}-macos.tar.gz"
tar -C "$WORK" -czf "$TARBALL" pkg
SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"

echo
echo "Done."
echo "  Artifact: $TARBALL"
echo "  sha256:   $SHA"
echo
echo "Next: attach the tarball to the GitHub release for v${VERSION}, then set the"
echo "formula's url to that asset and sha256 to the value above."
rm -rf "$WORK"
