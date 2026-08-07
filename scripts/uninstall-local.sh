#!/bin/bash
# Remove the manual (non-Homebrew) install.
set -euo pipefail
AGENT="$HOME/Library/LaunchAgents/com.zsoldier.mic-music-pause.plist"
launchctl unload "$AGENT" 2>/dev/null || true
rm -f "$AGENT"
rm -f "$HOME/.local/bin/mic-music-pause" "$HOME/.local/bin/mic-music-pause-menubar"
rm -rf "$HOME/.local/libexec/mic-music-pause"
echo "Uninstalled. (State/logs left in ~/.local/state/mic-music-pause — remove manually if desired.)"
