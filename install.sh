#!/bin/bash
# Builds, installs to /Applications, launches, and enables launch-at-login.
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Usage Monitor.app"

./build.sh

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

pkill -f "$APP/Contents/MacOS/ClaudeUsageMonitor" 2>/dev/null || true
sleep 1
rm -rf "$DEST/$APP"
ditto "$APP" "$DEST/$APP"

"$DEST/$APP/Contents/MacOS/ClaudeUsageMonitor" --login on
open "$DEST/$APP"

echo "Installed: $DEST/$APP (launches automatically at login)"
