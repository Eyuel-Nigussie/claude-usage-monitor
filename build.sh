#!/bin/bash
# Builds "Claude Usage Monitor.app" from ClaudeUsageMonitor.swift
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Usage Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.latterrain.claude-usage-monitor</string>
    <key>CFBundleName</key>
    <string>Claude Usage Monitor</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsageMonitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

swiftc -O -o "$APP/Contents/MacOS/ClaudeUsageMonitor" ClaudeUsageMonitor.swift
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Run:   open \"$PWD/$APP\""
