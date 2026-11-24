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
# "update --verify" must refuse each, with a reason. "update --fetch" and "--install" must refuse
# when there is nothing newer, when the release's disk image is not at our address, when a game
# runs from the app, when the app's folder cannot be written, and what "--verify" refuses. The
# notice at a game's start comes once per version, and nothing is asked when it is turned off.
# The installed copy must be the same afterwards, file for file. Prints PASS or FAIL per case;
# exit status 1 when one failed.
#
# With a notarized build of a newer version that was never published ($TEST_DMG; made with
#   VERSION=0.2.99 NOTARIZE=0 RELEASE_DIR=$BUILD_ROOT/evidence/update-build CHANGELOG=<one with a
#   [0.2.99] section> macos/make-release.sh
# then the app notarized and stapled and the disk image made again), it also updates for real:
# the new app takes the old one's place and the old one goes once the new one has started; and
# when the new one never starts, the old one comes back.
#
# Environment overrides: BUILD_ROOT, TEST_VERSION, TEST_DMG, RELEASE_APP, RELEASE_DMG (default: the 0.2.0 release in
# $BUILD_ROOT/release), SIGN_IDENTITY (default: the first Developer ID Application identity).

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MACOS_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
RELEASE_APP=${RELEASE_APP:-$BUILD_ROOT/release/Protium.app}
RELEASE_DMG=${RELEASE_DMG:-$BUILD_ROOT/release/Protium-$(defaults read "${RELEASE_APP:-$BUILD_ROOT/release/Protium.app}/Contents/Info" CFBundleShortVersionString 2>/dev/null).dmg}
TEST_VERSION=${TEST_VERSION:-0.2.99}
# a version newer than any, for the images and announcements that must be refused
FAKE=99.0.0
TEST_DMG=${TEST_DMG:-$BUILD_ROOT/evidence/update-build/Protium-$TEST_VERSION.dmg}
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
    STEAMPLAY_HOME=$E/home PROTIUM_RELEASES_API=$E/releases.json PROTIUM_APP=$APP PROTIUM_UPDATE_CACHE=$E/cache \
        PROTIUM_UPDATE_NO_OPEN=1 \
        "$APP/Contents/SharedSupport/python/bin/python3" -I -B "$MACOS_DIR/steamplay" "$@"
}
before=$(tree_sum "$APP")

small_copy "$E/adhoc.app"
plist_set "$E/adhoc.app" CFBundleShortVersionString $FAKE
codesign --force --deep --sign - "$E/adhoc.app" 2>/dev/null
image_of "$E/adhoc.app" "$E/adhoc.dmg"

cp -Rc "$RELEASE_APP" "$E/changed.app" 2>/dev/null || ditto "$RELEASE_APP" "$E/changed.app"
echo "# changed after signing" >>"$E/changed.app/Contents/Resources/steamplay/steamplay-run.sh"
image_of "$E/changed.app" "$E/changed.dmg"

small_copy "$E/otherid.app"
plist_set "$E/otherid.app" CFBundleIdentifier com.example.notprotium
plist_set "$E/otherid.app" CFBundleShortVersionString $FAKE
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
refuse adhoc "$E/adhoc.dmg" $FAKE "not signed by Protium's developer"
refuse changed "$E/changed.dmg" "$released" "not signed by Protium's developer, or was changed"
refuse otherid "$E/otherid.dmg" $FAKE "not signed by Protium's developer"
refuse not-newer "$RELEASE_DMG" "$released" "is not newer than this one"
refuse not-announced "$RELEASE_DMG" 0.9.0 "not the 0.9.0 that was announced"
refuse not-an-image "$MACOS_DIR/steamplay" $FAKE "cannot be opened"

echo "== what GitHub says, and update --fetch and --install"
# releases FILE VERSION ADDRESS: a list of releases as GitHub gives it, with the released one below
releases() {
    python3 -I - "$1" "$2" "$3" "$released" <<'PY'
import json, sys
out, version, address, released = sys.argv[1:5]
def release(v, url, body):
    return {"tag_name": "v" + v, "html_url": "https://github.com/0xLeathery/protium/releases/tag/v" + v, "draft": False,
            "prerelease": False, "body": body + "\n\n## Requirements\n\n- a Mac", "assets": [{"browser_download_url": url}]}
ours = "https://github.com/0xLeathery/protium/releases/download/v%s/Protium-%s.dmg"
listed = [release(released, ours % (released, released), "### Fixed\n\n- the released one")]
if version:
    listed.insert(0, release(version, address or ours % (version, version), "### Added\n\n- The first new thing.\n- The second."))
json.dump(listed, open(out, "w"))
PY
}
# says CASE WORDS command...: the command's output must have WORDS
says() {
    local name=$1 words=$2 out
    shift 2
    out=$("$@" 2>&1)
    echo "$out" >"$E/$name.out"
    echo "$out" | grep -q -e "$words" && pass "$name" "$(echo "$out" | grep -e "$words" | head -1 | cut -c1-150)" || fail "$name" "no \"$words\" in: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"
}
releases "$E/releases.json" "" ""
says none-newer "refused: there is no newer version" steamplay update --fetch
releases "$E/releases.json" $FAKE "https://example.com/Protium-$FAKE.dmg"
says other-address "refused: release $FAKE has no disk image of ours" steamplay update --fetch
releases "$E/releases.json" $FAKE ""
says changes "^- The first new thing" steamplay version --check --now
[ "$(steamplay version --check | grep -c '^Protium ')" = 1 ] && pass changes-only-newer "only the newer version's changes are listed" || fail changes-only-newer "$(steamplay version --check | grep '^Protium ' | tr '\n' ' ')"
says fetch-adhoc "refused: it is not signed by Protium's developer" env PROTIUM_UPDATE_IMAGE="$E/adhoc.dmg" bash -c "$(declare -f steamplay); E='$E' APP='$APP' MACOS_DIR='$MACOS_DIR'; steamplay update --fetch"
[ -z "$(ls "$E/cache" 2>/dev/null | grep dmg)" ] && pass fetch-cleans "a refused download does not stay" || fail fetch-cleans "left: $(ls "$E/cache")"
# a game running from the app: its wineserver, kept alive on a scratch prefix
mkdir -p "$E/pfx"
WINEPREFIX=$E/pfx "$APP/Contents/SharedSupport/runtime/bin/wineserver" -f -p10 >/dev/null 2>&1 &
perl -e 'select(undef, undef, undef, 1.5)'
says game-running "refused: a game is running from this Protium" steamplay update --fetch
says game-running-install "refused: a game is running from this Protium" steamplay update --install "$E/adhoc.dmg" $FAKE
WINEPREFIX=$E/pfx "$APP/Contents/SharedSupport/runtime/bin/wineserver" -k >/dev/null 2>&1
wait 2>/dev/null
chmod a-w "$E/Applications"
says not-writable "cannot be written by this user" steamplay update --install "$E/adhoc.dmg" $FAKE
chmod u+w "$E/Applications"
says install-adhoc "refused: it is not signed by Protium's developer" steamplay update --install "$E/adhoc.dmg" $FAKE
[ -z "$(ls -A "$E/Applications" | grep -v '^Protium.app$')" ] && pass install-cleans "nothing is left next to the app" || fail install-cleans "left: $(ls -A "$E/Applications" | tr '\n' ' ')"
[ ! -e "$E/home/update-pending.json" ] && pass no-pending "no update is pending after refusals" || fail no-pending "update-pending.json was written"

echo "== the notice when a game starts"
says notice "^notify $FAKE The first new thing" env PROTIUM_NOTIFY_TEST=1 bash -c "$(declare -f steamplay); E='$E' APP='$APP' MACOS_DIR='$MACOS_DIR'; steamplay version --notify"
[ -z "$(PROTIUM_NOTIFY_TEST=1 steamplay version --notify)" ] && pass notice-once "the second game start says nothing" || fail notice-once "it was told twice"
steamplay updates off >/dev/null
rm -f "$E/home/update-check.json"
says check-off "^check off" steamplay version --check --now
[ ! -e "$E/home/update-check.json" ] && [ -z "$(PROTIUM_NOTIFY_TEST=1 steamplay version --notify)" ] && pass off-asks-nothing "turned off: nothing is asked, kept or told" || fail off-asks-nothing "something was asked or told"
steamplay updates on >/dev/null

after=$(tree_sum "$APP")
[ "$before" = "$after" ] && pass unchanged "after every refusal the installed copy is the same, file for file" || fail unchanged "the installed copy changed"
codesign --verify --deep --strict "$APP" 2>/dev/null && pass seal "the installed copy's signature still verifies" || fail seal "the installed copy's signature no longer verifies"

# A real update, when there is a notarized build of a newer version to update to ($TEST_DMG,
# of version $TEST_VERSION; never published). No window opens: the check plays the new app's
# part and writes "started" itself, or does not.
newer_than_released() { [ "$1" != "$released" ] && [ "$(printf '%s\n%s\n' "$released" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]; }
if [ -f "$TEST_DMG" ] && newer_than_released "$TEST_VERSION"; then
    echo "== a real update to $TEST_VERSION, and one whose new app never starts"
    releases "$E/releases.json" "$TEST_VERSION" ""
    wait_for() {    # wait_for SECONDS test...
        local n=0 limit=$(($1 * 4))
        shift
        until "$@" 2>/dev/null; do n=$((n + 1)); [ $n -gt $limit ] && return 1; perl -e 'select(undef, undef, undef, 0.25)'; done
    }
    version_of() { cat "$1/Contents/Resources/steamplay/VERSION" 2>/dev/null; }
    in_place() { [ "$(version_of "$APP")" = "$1" ]; }
    says update-fetch "^ok fetched .*Protium-$TEST_VERSION.dmg $TEST_VERSION" env PROTIUM_UPDATE_IMAGE="$TEST_DMG" bash -c "$(declare -f steamplay); E='$E' APP='$APP' MACOS_DIR='$MACOS_DIR'; steamplay update --fetch"
    says update-install "^ok installing $TEST_VERSION" steamplay update --install "$E/cache/Protium-$TEST_VERSION.dmg" "$TEST_VERSION"
    if wait_for 20 in_place "$TEST_VERSION"; then
        pass update-swapped "the app in place is $TEST_VERSION, the old one waits next to it"
    else
        fail update-swapped "the app in place is $(version_of "$APP")"
    fi
    # the new app would say this on its first start
    python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["started"]=d["new"]; json.dump(d, open(p,"w"))' "$E/home/update-pending.json"
    wait_for 10 test ! -e "$E/Applications/.Protium-old.app" && pass update-done "the old app is gone once the new one has started" || fail update-done "the old app is still there"
    codesign --verify --deep --strict "$APP" 2>/dev/null && spctl --assess --type execute "$APP" 2>/dev/null \
        && pass update-seal "the updated app verifies and Gatekeeper accepts it" || fail update-seal "the updated app does not verify"
    [ -z "$(ls -A "$E/Applications" | grep -v '^Protium.app$')" ] && pass update-clean "nothing else is left in the folder" || fail update-clean "left: $(ls -A "$E/Applications" | tr '\n' ' ')"

    # again from the released version, and this time nobody says "started"
    rm -rf "$APP" "$E/home/update-pending.json"
    cp -Rc "$RELEASE_APP" "$APP" 2>/dev/null || ditto "$RELEASE_APP" "$APP"
    steamplay update --install "$TEST_DMG" "$TEST_VERSION" >"$E/rollback.out" 2>&1
    wait_for 20 in_place "$TEST_VERSION" && pass rollback-swapped "the new app is put in place" || fail rollback-swapped "the new app was never put in place: $(cat "$E/rollback.out")"
    if wait_for 45 grep -q '"failed"' "$E/home/update-pending.json" && [ "$(version_of "$APP")" = "$released" ]; then
        pass rollback "the new app did not start, and $released is back in place"
    else
        fail rollback "the app in place is $(version_of "$APP"); pending: $(cat "$E/home/update-pending.json" 2>/dev/null)"
    fi
    codesign --verify --deep --strict "$APP" 2>/dev/null && pass rollback-seal "the app put back verifies" || fail rollback-seal "the app put back does not verify"
    [ -z "$(ls -A "$E/Applications" | grep -v '^Protium.app$')" ] && pass rollback-clean "nothing else is left in the folder" || fail rollback-clean "left: $(ls -A "$E/Applications" | tr '\n' ' ')"
else
    echo "SKIP  a real update: no notarized test build newer than $released at $TEST_DMG (see the head of this file)"
fi

mount | grep -q protium-update- && fail mounts "a disk image is still mounted" || pass mounts "no disk image left mounted"

exit $FAILED
