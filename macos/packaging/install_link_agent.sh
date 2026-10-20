#!/bin/sh
set -eu

APP_PATH=${1:-/Applications/Ligament 2FA.app}
AGENT_PATH="$APP_PATH/Contents/MacOS/link-agent"
PLIST_SOURCE="$APP_PATH/Contents/Resources/com.ligament.link-agent.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.ligament.link-agent.plist"
DOMAIN="gui/$(id -u)"

if [ ! -x "$AGENT_PATH" ] || [ ! -f "$PLIST_SOURCE" ]; then
    echo "Ligament Link agent is missing from: $APP_PATH" >&2
    exit 1
fi
mkdir -p "$(dirname "$PLIST_DEST")"
sed "s|/Applications/Ligament 2FA.app|$APP_PATH|g" "$PLIST_SOURCE" > "$PLIST_DEST"
chmod 600 "$PLIST_DEST"
launchctl bootout "$DOMAIN" "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST_DEST"
launchctl enable "$DOMAIN/com.ligament.link-agent"
echo "Ligament Link agent is installed for the current macOS user."
