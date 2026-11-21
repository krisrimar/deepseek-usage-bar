#!/usr/bin/env bash
# Build DeepSeekUsageBar.app without an Xcode project.
#
#   ./build.sh              build for this machine's architecture
#   ./build.sh --universal  build arm64 + x86_64 and lipo them together
#
# The resulting bundle is ad-hoc signed, so it runs locally straight away.
# Set CODESIGN_IDENTITY to sign with a real Developer ID instead.
#
# A note on the toolchain, since this is the fragile part of the setup:
# SwiftPM is not usable here (Command Line Tools ships a libPackageDescription
# that fails to link even for a hello-world package, and there is no Xcode.app),
# so compilation is a direct swiftc invocation. That in turn means the sources
# must avoid @State and @AppStorage: as of Swift 5.9 those are macros, and a
# bare swiftc cannot load the SwiftUIMacros plugin that implements them.
# UI state therefore lives on AppModel as @Published instead. If you install
# full Xcode later, both constraints go away and Package.swift could return.

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

APP_NAME="DeepSeekUsageBar"
SRC="Sources/DeepSeekUsageBar"
BUILD_DIR="app/build"
APP="$BUILD_DIR/$APP_NAME.app"
MIN_MACOS="13.0"

SOURCES=("$SRC/DeepSeekUsageBar.swift" "$SRC/SettingsView.swift" "$SRC/PeakSchedule.swift" \
         "$SRC/Holidays.swift" "$SRC/Pricing.swift" \
         "$SRC/DeepSeekClient.swift" "$SRC/Keychain.swift" "$SRC/MenuBarItem.swift" \
         "$SRC/SpendRange.swift" "$SRC/Version.swift" "$SRC/UpdateCheck.swift" \
         "$SRC/Updater.swift")
# Charts is the spend popover's bar chart. It ships in the Command Line Tools
# SDK as a separate framework, so it needs naming here — SwiftUI and AppKit are
# pulled in implicitly, Charts is not.
FRAMEWORKS=(-framework SwiftUI -framework AppKit -framework Charts)

# Read back from the plist rather than duplicating it, for the same reason the
# app does: one place to bump.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)

UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

mkdir -p "$BUILD_DIR"

compile() {
  local arch="$1" out="$2"
  echo "  compiling $arch"
  # -parse-as-library is required for `@main` when building from source files
  # rather than through Xcode.
  swiftc -parse-as-library -O \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    "${FRAMEWORKS[@]}" \
    -o "$out" "${SOURCES[@]}"
}

BIN="$BUILD_DIR/$APP_NAME"
if [ "$UNIVERSAL" = "1" ]; then
  echo "Building $APP_NAME $VERSION — universal (macOS $MIN_MACOS+)"
  compile arm64  "$BUILD_DIR/$APP_NAME.arm64"
  compile x86_64 "$BUILD_DIR/$APP_NAME.x86_64"
  lipo -create -output "$BIN" "$BUILD_DIR/$APP_NAME.arm64" "$BUILD_DIR/$APP_NAME.x86_64"
  rm -f "$BUILD_DIR/$APP_NAME".{arm64,x86_64}
else
  echo "Building $APP_NAME $VERSION for $(uname -m) (macOS $MIN_MACOS+)"
  compile "$(uname -m)" "$BIN"
fi
chmod +x "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp app/Info.plist "$APP/Contents/Info.plist"

# Optional icon, if one has been generated alongside the sources.
if [ -f "app/$APP_NAME.icns" ]; then
  cp "app/$APP_NAME.icns" "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $APP_NAME" \
    "$APP/Contents/Info.plist" 2>/dev/null || true
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"
xattr -cr "$APP" 2>/dev/null || true
dot_clean "$APP" 2>/dev/null || true

# `--deep` is deprecated by Apple, so sign the executable explicitly.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "Signing with $CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
    "$APP/Contents/MacOS/$APP_NAME"
else
  codesign --force --sign - "$APP/Contents/MacOS/$APP_NAME"
fi
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP" 2>/dev/null || true

echo
echo "Built $APP_NAME $VERSION"
echo "Bundle:   $APP"
echo "Install:  ditto \"$APP\" /Applications/$APP_NAME.app"
echo "Run it:   open \"$APP\""
echo "Or:       \"$APP/Contents/MacOS/$APP_NAME\"   (logs to the terminal)"
