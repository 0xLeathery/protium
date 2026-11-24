#!/bin/bash
#
# Checks that Protium's updater installs our release and nothing else.
#
#   macos/tests/check-update.sh
#
# It works in $BUILD_ROOT/evidence/update/, never in /Applications or in the player's settings:
# "Applications/Protium.app" there is a copy of the released app ($RELEASE_APP), which this
# checkout's steamplay acts for, and STEAMPLAY_HOME and PROTIUM_RELEASES_API point into the folder.
# The disk images it tries to update from are made from copies of the same app:
#   adhoc      signed ad hoc, as anyone can
#   changed    our signature, with a file changed after signing
#   otherid    signed with the Developer ID, under another bundle identifier
#   genuine    the released disk image itself ($RELEASE_DMG), which is not newer than the copy
# "update --verify" must refuse each, with a reason, and the installed copy must be the same
# afterwards, file for file. Prints PASS or FAIL per case; exit status 1 when one failed.
#
# Environment overrides: BUILD_ROOT, RELEASE_APP, RELEASE_DMG (default: the 0.2.0 release in
# $BUILD_ROOT/release), SIGN_IDENTITY (default: the first Developer ID Application identity).

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MACOS_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
RELEASE_APP=${RELEASE_APP:-$BUILD_ROOT/release/Protium.app}
RELEASE_DMG=${RELEASE_DMG:-$BUILD_ROOT/release/Protium-0.2.0.dmg}
SIGN_IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}
E=$BUILD_ROOT/evidence/update
[ -d "$RELEASE_APP" ] && [ -f "$RELEASE_DMG" ] || { echo "check-update.sh: no released app and disk image in $BUILD_ROOT/release" >&2; exit 2; }

FAILED=0
pass() { echo "PASS  $1: $2"; }
fail() { echo "FAIL  $1: $2"; FAILED=1; }
released=$(defaults read "$RELEASE_APP/Contents/Info" CFBundleShortVersionString)
plist_set() { /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1/Contents/Info.plist"; }
# an image of one app, uncompressed: these are made to be refused, not shipped
image_of() {
    local stage=$E/stage
    rm -rf "$stage" "$2"
    mkdir -p "$stage"
    mv "$1" "$stage/Protium.app"
    hdiutil create -quiet -volname Protium -srcfolder "$stage" -fs APFS -format UDRO "$2" || return 1
    rm -rf "$stage"
}
# the app without its Wine: enough to be an app, and quick to copy and sign
small_copy() {
    rm -rf "$1"
    mkdir -p "$1"
    rsync -a --exclude SharedSupport "$RELEASE_APP/" "$1/"
}
tree_sum() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1); }

rm -rf "$E"
mkdir -p "$E/Applications" "$E/home"
echo "== the installed copy ($released) and the disk images to refuse"
cp -Rc "$RELEASE_APP" "$E/Applications/Protium.app" 2>/dev/null || ditto "$RELEASE_APP" "$E/Applications/Protium.app"
APP=$E/Applications/Protium.app
# this checkout's steamplay acts for the copy (PROTIUM_APP), run by the copy's own Python. The copy
# itself is never changed: macOS kills what is started from a notarized app whose files changed,
# and moves the app to the Trash.
steamplay() {
    STEAMPLAY_HOME=$E/home PROTIUM_RELEASES_API=$E/releases.json PROTIUM_APP=$APP \
        "$APP/Contents/SharedSupport/python/bin/python3" -I -B "$MACOS_DIR/steamplay" "$@"
}
before=$(tree_sum "$APP")

small_copy "$E/adhoc.app"
plist_set "$E/adhoc.app" CFBundleShortVersionString 0.2.99
codesign --force --deep --sign - "$E/adhoc.app" 2>/dev/null
image_of "$E/adhoc.app" "$E/adhoc.dmg"

cp -Rc "$RELEASE_APP" "$E/changed.app" 2>/dev/null || ditto "$RELEASE_APP" "$E/changed.app"
echo "# changed after signing" >>"$E/changed.app/Contents/Resources/steamplay/steamplay-run.sh"
image_of "$E/changed.app" "$E/changed.dmg"

small_copy "$E/otherid.app"
plist_set "$E/otherid.app" CFBundleIdentifier com.example.notprotium
plist_set "$E/otherid.app" CFBundleShortVersionString 0.2.99
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$E/otherid.app" 2>/dev/null
image_of "$E/otherid.app" "$E/otherid.dmg"

echo "== update --verify"
# refuse CASE IMAGE VERSION WORDS: the command must fail, say "refused:" with WORDS in the reason
refuse() {
    local out status
    out=$(steamplay update --verify "$2" "$3" 2>&1)
    status=$?
    echo "$out" >"$E/$1.out"
    if [ $status = 0 ] || ! echo "$out" | grep -q '^refused: '; then
        fail "$1" "was not refused: $out"
    elif ! echo "$out" | grep -q -e "$4"; then
        fail "$1" "refused for another reason: $out"
    else
        pass "$1" "$(echo "$out" | tail -1 | cut -c1-150)"
    fi
}
refuse adhoc "$E/adhoc.dmg" 0.2.99 "not signed by Protium's developer"
refuse changed "$E/changed.dmg" "$released" "not signed by Protium's developer, or was changed"
refuse otherid "$E/otherid.dmg" 0.2.99 "not signed by Protium's developer"
refuse not-newer "$RELEASE_DMG" "$released" "is not newer than this one"
refuse not-announced "$RELEASE_DMG" 0.9.0 "not the 0.9.0 that was announced"
refuse not-an-image "$MACOS_DIR/steamplay" 0.2.99 "cannot be opened"
mount | grep -q protium-update- && fail mounts "a disk image is still mounted" || pass mounts "no disk image left mounted"

after=$(tree_sum "$APP")
[ "$before" = "$after" ] && pass unchanged "the installed copy is the same, file for file" || fail unchanged "the installed copy changed"
codesign --verify --deep --strict "$APP" 2>/dev/null && pass seal "the installed copy's signature still verifies" || fail seal "the installed copy's signature no longer verifies"
exit $FAILED
