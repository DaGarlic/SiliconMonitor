#!/bin/zsh
# Builds SiliconMonitor-<version>.dmg: the app plus an Applications shortcut, ready to upload as a release.
#   ./tools/make_dmg.sh            version 1.0
#   ./tools/make_dmg.sh 1.2        version 1.2
set -e
cd "$(dirname "$0")/.."
VERSION="${1:-1.0}"
VERSION="$VERSION" ./bundle.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R SiliconMonitor.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

OUT="SiliconMonitor-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "SiliconMonitor" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
