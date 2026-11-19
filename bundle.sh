#!/bin/zsh
# Builds a release binary and wraps it in SiliconMonitor.app (menu bar only, no Dock icon).
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-1.3}"   # shown in Finder's Get Info; override with VERSION=1.3 ./bundle.sh
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
  <key>NSAudioCaptureUsageDescription</key><string>SiliconMonitor listens to the audio your Mac plays so the Apple logo can flash to the beat. Nothing is recorded or stored.</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# Sign with the local self-signed identity when it exists: a stable signature keeps the Accessibility and
# Input Monitoring grants across rebuilds. Falls back to ad-hoc (grants then reset on every rebuild).
# For distribution: DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./bundle.sh
# signs with the hardened runtime, which Apple's notarization requires.
IDENTITY="SiliconMonitor Local Signing"
# codesign refuses files carrying Finder info / resource forks, and a synced Desktop can re-add them between
# commands, so strip them right before each attempt and retry.
sign() { for i in 1 2 3 4 5; do xattr -cr "$APP"; codesign "$@" && return 0; sleep 1; done; return 1; }
if [ -n "$DEVELOPER_ID" ]; then
  sign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
elif security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  sign --force --sign "$IDENTITY" "$APP"
else
  echo "Note: identity '$IDENTITY' not found; signing ad-hoc"
  sign --force --sign - "$APP"
fi
echo "Built $APP"
