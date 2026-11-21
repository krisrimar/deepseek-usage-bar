#!/bin/sh
# Install or upgrade DeepSeek Usage Bar from the latest GitHub release.
#
#   curl -fsSL https://github.com/krisrimar/deepseek-usage-bar/releases/latest/download/install.sh | sh
#
# The release is a universal .app in a zip, with a SHA-256 beside it. This puts
# it in /Applications when that is writable and ~/Applications otherwise, clears
# the quarantine flag a browser would have added, and opens it. Nothing needs
# sudo. The app is not notarized, which is why this path exists: files curl
# writes are not quarantined, so macOS opens the app without the unsigned-app
# prompt.
#
# For testing, these change where it reads and writes:
#   DEEPSEEK_RELEASE_URL  the release's download folder
#                         (default: the latest GitHub release)
#   DEEPSEEK_APP_DIR      where DeepSeek Usage Bar.app goes
#                         (default: /Applications, or ~/Applications)
set -eu

REPO="krisrimar/deepseek-usage-bar"
BASE="${DEEPSEEK_RELEASE_URL:-https://github.com/$REPO/releases/latest/download}"
ZIP="DeepSeekUsageBar-macos-universal.zip"
SHA="$ZIP.sha256"
APP="DeepSeek Usage Bar.app"
EXECUTABLE="DeepSeekUsageBar"
# The 0.5.0 release used the no-space bundle name. An upgrade must remove that
# copy, or the menu bar ends up with two icons.
LEGACY_APP="DeepSeekUsageBar.app"

say() { printf '%s\n' "$*"; }
fail() {
    printf 'deepseek-usage-bar install: %s\n' "$*" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail "this installer is for macOS"

macos_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos_major" -ge 13 ] || fail "macOS 13 or later is required"

if [ -n "${DEEPSEEK_APP_DIR:-}" ]; then
    app_dir=$DEEPSEEK_APP_DIR
elif [ -w /Applications ]; then
    app_dir=/Applications
else
    app_dir=$HOME/Applications
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say "Downloading DeepSeek Usage Bar…"
curl -fsSL "$BASE/$ZIP" -o "$work/$ZIP" ||
    fail "couldn't download $BASE/$ZIP"
curl -fsSL "$BASE/$SHA" -o "$work/$SHA" ||
    fail "couldn't download $BASE/$SHA"

want=$(awk '{print tolower($1)}' "$work/$SHA")
got=$(shasum -a 256 "$work/$ZIP" | awk '{print $1}')
[ -n "$want" ] && [ "$want" = "$got" ] ||
    fail "the download doesn't match its checksum (expected $want, got $got): not installing"

ditto -x -k "$work/$ZIP" "$work/unzipped"
[ -x "$work/unzipped/$APP/Contents/MacOS/$EXECUTABLE" ] ||
    fail "the download has no $APP in it: not installing"

dest="$app_dir/$APP"
legacy="$app_dir/$LEGACY_APP"

quit_app() {
    _app="$1"
    pgrep -f "$_app/Contents/MacOS/$EXECUTABLE" >/dev/null 2>&1 || return 0
    say "Quitting the running copy…"
    pkill -f "$_app/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
    i=0
    while pgrep -f "$_app/Contents/MacOS/$EXECUTABLE" >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -ge 50 ] && break
        sleep 0.1
    done
}

quit_app "$dest"
if [ -d "$legacy" ] && [ "$legacy" != "$dest" ]; then
    say "Removing the old ${LEGACY_APP}…"
    quit_app "$legacy"
    rm -rf "$legacy"
fi

mkdir -p "$app_dir"
rm -rf "$dest"
ditto "$work/unzipped/$APP" "$dest"
# Only a browser marks downloads; clear it in case this was run on a copy that
# came through one.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$dest/Contents/Info.plist" 2>/dev/null || echo "?")

open "$dest" >/dev/null 2>&1 || true

say ""
say "Installed DeepSeek Usage Bar ${version} in ${app_dir}."
say "It is running in the menu bar now; later updates come from Settings → Updates."
