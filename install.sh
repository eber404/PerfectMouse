#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PerfectMouse"
BUNDLE_ID="com.eber.perfectmouse"
APP_DIR="$HOME/Applications"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools não encontrados. Rode: xcode-select --install"
    exit 1
fi

./build.sh

mkdir -p "$APP_DIR"
pkill -f "$APP_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -rf "$APP_DIR/$APP_NAME.app"
cp -R "$APP_NAME.app" "$APP_DIR/"
xattr -dr com.apple.quarantine "$APP_DIR/$APP_NAME.app" 2>/dev/null || true

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array><string>$APP_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
EOF

launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"

sleep 1
echo
echo "Instalado em $APP_DIR/$APP_NAME.app"
echo "Inicia sozinho no login: $AGENT"
echo
echo "Se o macOS não pedir a permissão, abra o ícone na barra de menus"
echo "e clique em 'Abrir Ajustes' para autorizar em Acessibilidade."
