#!/bin/zsh
# Regenerates Resources/AppIcon.icns from tools/make_icon.swift
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift tools/make_icon.swift "$TMP/icon1024.png"
SET="$TMP/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
