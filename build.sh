#!/bin/bash
# 編譯 TZSync.app（純命令列 swiftc，免 Xcode IDE）。
set -euo pipefail
cd "$(dirname "$0")"

APP="TZSync.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "== 清理舊 bundle =="
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "== 寫 Info.plist =="
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TZSync</string>
    <key>CFBundleDisplayName</key><string>TZSync</string>
    <key>CFBundleExecutable</key><string>TZSync</string>
    <key>CFBundleIdentifier</key><string>local.tzsync.app</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>TZSync — 本機時區跟隨代理出口</string>
</dict>
</plist>
PLIST

echo "== swiftc 編譯 =="
swiftc -O -framework Cocoa src/main.swift -o "$MACOS/TZSync"

echo "== 完成：$APP =="
echo "啟動： open $APP     （或雙擊）"
echo "自測： '$MACOS/TZSync' --detect"
