#!/bin/zsh
# Builds SiliconMonitor-<version>.dmg: the app plus an Applications shortcut, ready to upload as a release.
#   ./tools/make_dmg.sh            version 1.4
#   ./tools/make_dmg.sh 1.4
set -e
cd "$(dirname "$0")/.."
VERSION="${1:-1.4}"
VERSION="$VERSION" ./bundle.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R SiliconMonitor.app "$STAGE/"
# A synced folder (iCloud Desktop) adds Finder / file-provider attributes to the app after it was signed, which
# makes `codesign --verify` fail on the copy people download. The staging copy is outside it, so clean it here.
xattr -cr "$STAGE/SiliconMonitor.app"
codesign --verify --deep --strict "$STAGE/SiliconMonitor.app"
ln -s /Applications "$STAGE/Applications"

OUT="SiliconMonitor-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "SiliconMonitor" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null

# Notarize and staple when DEVELOPER_ID is set and a keychain profile exists (see README: Notarization):
#   xcrun notarytool store-credentials siliconmonitor-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$OUT"
  xcrun notarytool submit "$OUT" --keychain-profile "${NOTARY_PROFILE:-siliconmonitor-notary}" --wait
  xcrun stapler staple "$OUT"
fi
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
