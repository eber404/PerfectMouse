#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP="PerfectMouse.app"

rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library main.swift -o build/PerfectMouse
cp build/PerfectMouse "$APP/Contents/MacOS/PerfectMouse"
cp Info.plist "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "built $APP"
