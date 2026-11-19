#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.eber.perfectmouse"
APP_DIR="$HOME/Applications"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

launchctl unload "$AGENT" 2>/dev/null || true
rm -f "$AGENT"

pkill -f "$APP_DIR/PerfectMouse.app/Contents/MacOS/PerfectMouse" 2>/dev/null || true
sleep 1

rm -rf "$APP_DIR/PerfectMouse.app"
rm -rf "$HOME/Library/Application Support/PerfectMouse"
rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" 2>/dev/null || true
rm -f "$HOME/Library/Logs/PerfectMouse.log"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "PerfectMouse removido."
