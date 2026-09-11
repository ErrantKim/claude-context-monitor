#!/bin/bash
# Builds ClaudeContextMonitor.app into ./build.
#
# The status line collector ships inside the bundle so that an install does not
# depend on this checkout staying where it is.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeContextMonitor.app"
MACOS="$APP/Contents/MacOS"

mkdir -p build
swiftc -O -framework AppKit -o build/ClaudeContextMonitor src/app.swift
swiftc -O -o build/cc-widget-statusline src/statusline.swift

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"
cp build/ClaudeContextMonitor build/cc-widget-statusline "$MACOS/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Claude Context Monitor</string>
  <key>CFBundleDisplayName</key>       <string>Claude Context Monitor</string>
  <key>CFBundleIdentifier</key>        <string>local.claude-context-monitor</string>
  <key>CFBundleExecutable</key>        <string>ClaudeContextMonitor</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Reads the front terminal tab's tty so the menu bar can show that session's context usage.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
