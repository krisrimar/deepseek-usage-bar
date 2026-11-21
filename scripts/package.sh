#!/usr/bin/env bash
# Build the release artifacts into dist/.
#
#   ./scripts/package.sh
#
# Universal .app, a zip for the in-app updater and install.sh, a drag-to-
# Applications dmg, and a SHA-256 file beside each. Asset names are stable so
# `releases/latest/download/<name>` keeps working across versions; the release
# tag carries the version instead.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" app/Info.plist)
APP_BUNDLE="DeepSeek Usage Bar.app"
APP="app/build/$APP_BUNDLE"
DIST="dist"

ZIP="DeepSeekUsageBar-macos-universal.zip"
DMG="DeepSeekUsageBar-macos-universal.dmg"

echo "Packaging DeepSeek Usage Bar $VERSION ($BUILD)"

rm -rf "$DIST"
mkdir -p "$DIST"

./app/build.sh --universal

# The bundle's own plist is what the updater validates, so check it before
# anything is published under this version's name.
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP/Contents/Info.plist")
[ "$PLIST_VERSION" = "$VERSION" ] || {
    echo "package: built app reports $PLIST_VERSION, expected $VERSION" >&2
    exit 1
}

# `ditto` keeps symlinks, resource forks and the extended attributes a bundle
# needs; `zip` alone does not, and the app would arrive damaged.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_BUNDLE"
ditto -c -k --keepParent "$STAGE/$APP_BUNDLE" "$DIST/$ZIP"

# A dmg with the usual Applications alias, for people who would rather drag
# than curl.
DMG_STAGE=$(mktemp -d)
ditto "$APP" "$DMG_STAGE/$APP_BUNDLE"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "DeepSeek Usage Bar" \
    -srcfolder "$DMG_STAGE" -ov -format UDZO "$DIST/$DMG"
rm -rf "$DMG_STAGE"

# Checksums, written from inside dist/ so the file names in them are relative.
(
    cd "$DIST"
    shasum -a 256 "$ZIP" > "$ZIP.sha256"
    shasum -a 256 "$DMG" > "$DMG.sha256"
)

cp install.sh "$DIST/install.sh"

echo
echo "Artifacts in $DIST:"
ls -lh "$DIST"
