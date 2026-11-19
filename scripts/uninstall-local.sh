#!/bin/bash
# Remove the manual (non-Homebrew) install.
set -euo pipefail
AGENT="$HOME/Library/LaunchAgents/com.zsoldier.mic-music-pause.plist"
SERVICE="gui/$(id -u)/com.zsoldier.mic-music-pause"
if launchctl print "$SERVICE" >/dev/null 2>&1; then
  launchctl bootout "$SERVICE"
fi
rm -f "$AGENT"
rm -f "$HOME/.local/bin/mic-music-pause" "$HOME/.local/bin/mic-music-pause-menubar"
rm -rf "$HOME/.local/libexec/mic-music-pause"
rm -rf "/Applications/mic-music-pause.app"
echo "Uninstalled. (State/logs left in ~/.local/state/mic-music-pause — remove manually if desired.)"
