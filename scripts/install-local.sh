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

echo "Compiling menu bar app..."
xcrun swiftc -O -o "$LIBEXEC_DIR/mic-music-pause-menubar" "$REPO_DIR/src/menubar.swift"

echo "Installing CLI to $BIN_DIR..."
install -m 0755 "$REPO_DIR/bin/mic-music-pause" "$BIN_DIR/mic-music-pause"
install -m 0755 "$LIBEXEC_DIR/mic-music-pause-menubar" "$BIN_DIR/mic-music-pause-menubar"

echo "Writing LaunchAgent..."
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.zsoldier.mic-music-pause</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/mic-music-pause-menubar</string>
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
