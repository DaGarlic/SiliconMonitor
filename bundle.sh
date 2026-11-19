#!/bin/zsh
# Builds a release binary and wraps it in SiliconMonitor.app (menu bar only, no Dock icon).
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-1.2}"   # shown in Finder's Get Info; override with VERSION=1.2 ./bundle.sh
swift build -c release
APP=SiliconMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SiliconMonitor "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SiliconMonitor</string>
  <key>CFBundleIdentifier</key><string>local.siliconmonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>SiliconMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# Sign with the local self-signed identity when it exists: a stable signature keeps the Accessibility and
# Input Monitoring grants across rebuilds. Falls back to ad-hoc (grants then reset on every rebuild).
# For distribution: DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./bundle.sh
# signs with the hardened runtime, which Apple's notarization requires.
IDENTITY="SiliconMonitor Local Signing"
if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
elif security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "Note: identity '$IDENTITY' not found; signing ad-hoc"
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
