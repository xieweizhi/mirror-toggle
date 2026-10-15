#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="../Mirror Toggle.app"
mkdir -p "$APP/Contents/MacOS"
swiftc main.swift -O -target arm64-apple-macosx13.0 -o "$APP/Contents/MacOS/MirrorToggle" -framework AppKit -framework CoreGraphics -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/MirrorToggle" --self-test
echo "Built: $APP"
