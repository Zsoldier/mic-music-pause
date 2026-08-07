#!/bin/bash
# Manual (non-Homebrew) installer: compiles the detector, installs the CLI to
# ~/.local/bin, and loads a launchd LaunchAgent that runs at login.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
LIBEXEC_DIR="$HOME/.local/libexec/mic-music-pause"
AGENT="$HOME/Library/LaunchAgents/com.zsoldier.mic-music-pause.plist"

mkdir -p "$BIN_DIR" "$LIBEXEC_DIR" "$HOME/Library/LaunchAgents"

echo "Compiling detector..."
xcrun swiftc -O -o "$LIBEXEC_DIR/micstate" "$REPO_DIR/src/micstate.swift"

echo "Building menu bar app bundle..."
APP="$LIBEXEC_DIR/mic-music-pause.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -o "$APP/Contents/MacOS/mic-music-pause-menubar" "$REPO_DIR/src/menubar.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>mic-music-pause</string>
  <key>CFBundleDisplayName</key><string>mic-music-pause</string>
  <key>CFBundleIdentifier</key><string>com.zsoldier.mic-music-pause</string>
  <key>CFBundleExecutable</key><string>mic-music-pause-menubar</string>
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
/usr/bin/codesign --force --sign - --identifier com.zsoldier.mic-music-pause "$APP" 2>/dev/null || true

echo "Installing CLI to $BIN_DIR..."
install -m 0755 "$REPO_DIR/bin/mic-music-pause" "$BIN_DIR/mic-music-pause"
cat > "$BIN_DIR/mic-music-pause-menubar" <<SH
#!/bin/bash
exec "$APP/Contents/MacOS/mic-music-pause-menubar" "\$@"
SH
chmod 0755 "$BIN_DIR/mic-music-pause-menubar"

echo "Writing LaunchAgent..."
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.zsoldier.mic-music-pause</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/mic-music-pause-menubar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/.local/state/mic-music-pause/watch.log</string>
  <key>StandardErrorPath</key><string>$HOME/.local/state/mic-music-pause/watch.log</string>
</dict>
</plist>
PLIST

mkdir -p "$HOME/.local/state/mic-music-pause"
launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"

echo "Installed and started — look for the music-note icon in your menu bar."
echo "Verify with: launchctl list | grep mic-music-pause"
echo "Make sure $BIN_DIR is on your PATH."
