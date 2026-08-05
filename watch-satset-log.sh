#!/bin/sh
# Runs the installed Satset in the foreground so its diagnostics are visible.
# Unified logging redacts NSLog interpolation as <private>, so we read stderr instead.
# Quit the menu bar instance first; Ctrl-C here to stop.
set -e
APP=/Applications/Satset.app
pkill -f "Satset.app/Contents/MacOS" 2>/dev/null || true
sleep 1
echo "--- Satset diagnostics (Ctrl-C to quit) ---"
exec "$APP/Contents/MacOS/Satset"
