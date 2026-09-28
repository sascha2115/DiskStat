#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-$HOME/Applications/DiskStat.app}"
LABEL="com.sascha.diskstat"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [[ ! -d "$APP_PATH" ]]; then
    echo "App not found at: $APP_PATH"
    echo "Build/copy DiskStat.app first, then re-run this script."
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

# The path is interpolated into XML below, so it has to be escaped: a path
# containing &, < or > would otherwise produce an invalid plist.
APP_PATH_XML="${APP_PATH//&/&amp;}"
APP_PATH_XML="${APP_PATH_XML//</&lt;}"
APP_PATH_XML="${APP_PATH_XML//>/&gt;}"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>${APP_PATH_XML}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
    </array>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "Installed login item via LaunchAgent: $PLIST_PATH"
