#!/usr/bin/env bash
# Run the test suites.
#
#   ./tests/run.sh                     peak/pricing tests, then HAR decode
#                                      tests if a capture is present
#   ./tests/run.sh path/to/capture.har pass an explicit capture
#
# The HAR suite skips when no capture exists, since the file holds real
# account data and is deliberately gitignored.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Sources/DeepSeekUsageBar"
TMP="$(mktemp -d)"

# Guards the release discipline rather than the code, and runs first because it
# is instant: the version the bundle will report and the changelog's newest
# release are the same number, or this fails before the compiles start.
echo "== version and changelog agreement =="
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)
# Newest release heading; "[Unreleased]" carries no number and so never matches.
LOG_VERSION=$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' CHANGELOG.md 2>/dev/null | head -1 || true)
if [ "$APP_VERSION" != "$LOG_VERSION" ]; then
  echo "  FAIL: app/Info.plist is $APP_VERSION, CHANGELOG.md's newest release is ${LOG_VERSION:-missing}" >&2
  echo "        Bump both in the same change." >&2
  exit 1
fi
echo "  $APP_VERSION — app/Info.plist and CHANGELOG.md agree"

# The updater and installer have to agree on the files a release publishes.
# They are separate programs with no shared header, so this is where drift
# between them is caught.
echo "== release asset names =="
ZIP_ASSET=$(sed -n 's/^ZIP="\(.*\)"$/\1/p' install.sh)
PKG_ZIP=$(sed -n 's/^ZIP="\(.*\)"$/\1/p' scripts/package.sh)
DMG_ASSET=$(sed -n 's/^DMG="\(.*\)"$/\1/p' scripts/package.sh)
if [ "$ZIP_ASSET" != "DeepSeekUsageBar-macos-universal.zip" ] || \
   [ "$PKG_ZIP" != "$ZIP_ASSET" ] || \
   [ "$DMG_ASSET" != "DeepSeekUsageBar-macos-universal.dmg" ]; then
  echo "  FAIL: install.sh and scripts/package.sh disagree on the asset names" >&2
  echo "        install.sh zip=$ZIP_ASSET package.sh zip=$PKG_ZIP dmg=$DMG_ASSET" >&2
  exit 1
fi
grep -q "static let zipAsset = \"$ZIP_ASSET\"" "$SRC/UpdateCheck.swift" ||
  { echo "  FAIL: UpdateCheck.zipAsset is not $ZIP_ASSET" >&2; exit 1; }
grep -q "static let dmgAsset = \"$DMG_ASSET\"" "$SRC/UpdateCheck.swift" ||
  { echo "  FAIL: UpdateCheck.dmgAsset is not $DMG_ASSET" >&2; exit 1; }
echo "  zip, checksum and dmg names agree"

echo "== peak schedule and pricing =="
swiftc -O -o "$TMP/peaktests" \
  "$SRC/PeakSchedule.swift" "$SRC/Holidays.swift" "$SRC/Pricing.swift" tests/PeakTests.swift
"$TMP/peaktests"

echo "== token normalisation =="
swiftc -O -o "$TMP/tokentests" \
  "$SRC/DeepSeekClient.swift" "$SRC/Pricing.swift" "$SRC/PeakSchedule.swift" \
  "$SRC/Holidays.swift" tests/TokenTests.swift
"$TMP/tokentests"

echo "== peak/off-peak tier attribution =="
swiftc -O -o "$TMP/tiertests" \
  "$SRC/DeepSeekClient.swift" "$SRC/Pricing.swift" "$SRC/PeakSchedule.swift" \
  "$SRC/Holidays.swift" tests/TierTests.swift
"$TMP/tiertests"

echo "== menu bar composition and spend totals =="
swiftc -O -o "$TMP/menubartests" \
  "$SRC/MenuBarItem.swift" "$SRC/DeepSeekClient.swift" "$SRC/Pricing.swift" \
  "$SRC/PeakSchedule.swift" "$SRC/Holidays.swift" tests/MenuBarTests.swift
"$TMP/menubartests"

echo "== spend ranges and daily folding =="
swiftc -O -o "$TMP/spendtests" \
  "$SRC/SpendRange.swift" "$SRC/DeepSeekClient.swift" "$SRC/Pricing.swift" \
  "$SRC/PeakSchedule.swift" "$SRC/Holidays.swift" tests/SpendTests.swift
"$TMP/spendtests"

echo "== update checks =="
swiftc -O -o "$TMP/updatetests" "$SRC/UpdateCheck.swift" tests/UpdateCheckTests.swift
"$TMP/updatetests"

echo "== usage decoding (captured HAR) =="
swiftc -O -o "$TMP/hartests" \
  "$SRC/DeepSeekClient.swift" "$SRC/Pricing.swift" "$SRC/PeakSchedule.swift" \
  "$SRC/Holidays.swift" tests/UsageDecodeTests.swift
"$TMP/hartests" "${1:-platform.deepseek.com.har}"
