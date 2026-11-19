#!/bin/bash
# Manual (non-Homebrew) installer: compiles the detector, installs the CLI to
# ~/.local/bin, and installs the menu bar app in /Applications.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
LIBEXEC_DIR="$HOME/.local/libexec/mic-music-pause"
AGENT="$HOME/Library/LaunchAgents/com.zsoldier.mic-music-pause.plist"
APP="/Applications/mic-music-pause.app"

if [ ! -w /Applications ]; then
  echo "Cannot write to /Applications. Run this installer from an account with permission to install apps." >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$LIBEXEC_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Compiling detector..."
xcrun swiftc -O -o "$LIBEXEC_DIR/micstate" "$REPO_DIR/src/micstate.swift"

echo "Building menu bar app bundle..."
STAGED_APP="$WORK/mic-music-pause.app"
mkdir -p "$STAGED_APP/Contents/MacOS"
mkdir -p "$STAGED_APP/Contents/Resources"
cp "$REPO_DIR/packaging/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
xcrun swiftc -parse-as-library -O -o "$STAGED_APP/Contents/MacOS/mic-music-pause-menubar" "$REPO_DIR/src/menubar.swift"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>mic-music-pause</string>
  <key>CFBundleDisplayName</key><string>mic-music-pause</string>
  <key>CFBundleIdentifier</key><string>com.zsoldier.mic-music-pause</string>
  <key>CFBundleExecutable</key><string>mic-music-pause-menubar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.0-local</string>
  <key>CFBundleVersion</key><string>0.0.0-local</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>mic-music-pause automatically pauses Apple Music when you join a call (Teams, Zoom, FaceTime, and similar) and resumes it when the call ends. To do that it needs permission to control the Music app: it only sends play and pause commands and reads whether Music is currently playing. It does not read your music library, files, messages, or any other personal data, and it never controls any other app.</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier com.zsoldier.mic-music-pause "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"

# Older local installs used KeepAlive, which relaunches the app after Quit.
SERVICE="gui/$(id -u)/com.zsoldier.mic-music-pause"
if launchctl print "$SERVICE" >/dev/null 2>&1; then
  launchctl bootout "$SERVICE"
fi
rm -f "$AGENT"

echo "Installing app to $APP..."
ditto "$STAGED_APP" "$APP"

echo "Installing CLI to $BIN_DIR..."
install -m 0755 "$REPO_DIR/bin/mic-music-pause" "$BIN_DIR/mic-music-pause"
cat > "$BIN_DIR/mic-music-pause-menubar" <<SH
#!/bin/bash
exec "$APP/Contents/MacOS/mic-music-pause-menubar" "\$@"
SH
chmod 0755 "$BIN_DIR/mic-music-pause-menubar"

open "$APP"

echo "Installed and started — look for the music-note icon in your menu bar."
echo "Quit from its menu; reopen mic-music-pause from Applications whenever you need it."
echo "To launch automatically at login, enable Start at login in the app's menu."
echo "Make sure $BIN_DIR is on your PATH."
