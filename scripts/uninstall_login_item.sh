#!/usr/bin/env bash
set -euo pipefail

LABEL="com.sascha.diskstat"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
APP_PATH="$HOME/Applications/DiskStat.app"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
echo "Removed login item: $PLIST_PATH"

# Only ever remove a bundle that really is DiskStat, so this can never delete an
# unrelated app that happens to sit at the same path.
if [[ -d "$APP_PATH" ]]; then
    if /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$APP_PATH/Contents/Info.plist" 2>/dev/null | grep -qx "$LABEL"; then
        rm -rf "$APP_PATH"
        echo "Removed app copy: $APP_PATH"
    else
        echo "Left alone (not bundle id $LABEL): $APP_PATH"
    fi
fi
