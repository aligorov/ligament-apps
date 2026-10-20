#!/bin/sh
set -eu

PLIST_DEST="$HOME/Library/LaunchAgents/com.ligament.link-agent.plist"
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN" "$PLIST_DEST" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"
echo "Ligament Link agent was removed for the current macOS user."
