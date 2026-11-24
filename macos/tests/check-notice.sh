#!/bin/bash
#
# Checks the banner Protium shows over a game when a newer version is out ("Protium
# --game-notice", see macos/app/Protium.swift).
#
#   macos/tests/check-notice.sh
#
# mouse_look_test.exe, a window over the whole screen with the pointer hidden, stands in for a
# game. The app's binary is built from this checkout and told that the checks' Wine is its own
# (PROTIUM_RUNTIME). Then:
#   no-game   with no game window, the notice shows nothing and ends by itself
#   shown     with the game up, its panel is a window on the game's screen, above the game's
#   drawn     that part of the screen has a picture while it shows, and the game's plain grey after
#   focus     the notice is not the application in front
#   click     a click at the panel's place arrives in the game
#   gone      the panel and its process are gone ten seconds later
# IT TAKES THE FRONT OF THE SCREEN AND THE POINTER for about half a minute: run it only when
# nobody is using the Mac. Logs go to $BUILD_ROOT/evidence/notice. Exit status 1 when one failed.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
E=$BUILD_ROOT/evidence/notice
PREFIX=${PREFIX:-$BUILD_ROOT/evidence/wave5/prefix}
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
WINE=$INSTALL_DIR/bin/wine
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=} WINEDEBUG=-all WINEPREFIX=$PREFIX
pgrep -f 'steamplay-run|steam\.exe' >/dev/null && { echo "check-notice.sh: a game is running; not now" >&2; exit 2; }
rm -rf "$E"; mkdir -p "$E"
FAILED=0
pass() { echo "PASS  $1: $2"; }
fail() { echo "FAIL  $1: $2"; FAILED=1; }
nap() { perl -e 'select(undef, undef, undef, shift)' "$1"; }

swiftc -swift-version 5 -O -target arm64-apple-macos27.0 -framework AppKit -framework UserNotifications \
    -o "$E/Protium" "$SCRIPT_DIR/../app/Protium.swift" || exit 2
clang -O1 -Wall -o "$E/list_windows" "$SCRIPT_DIR/list_windows.c" -framework CoreGraphics -framework CoreFoundation || exit 2
"$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang" -O2 -Wall -o "$E/mouse_look_test.exe" "$SCRIPT_DIR/mouse_look_test.c" -luser32 -lgdi32 || exit 2
swiftc -O -o "$E/mouse_feed" "$SCRIPT_DIR/mouse_feed.swift" || exit 2
# the notice's windows: PID, size, place, layer, on screen
panel() { "$E/list_windows" "$E" | awk -F'\t' '$2 ~ /x88$/ && $6 == 1'; }

s=$(date +%s)
PROTIUM_RUNTIME=$INSTALL_DIR PROTIUM_NOTICE_WAIT=3 "$E/Protium" --game-notice 9.9.9 "The first new thing." >/dev/null 2>&1
took=$(( $(date +%s) - s ))
[ $took -ge 2 ] && [ $took -le 8 ] && pass no-game "with no game it ended by itself after $took s" || fail no-game "it ran $took s"

"$WINE" "$E/mouse_look_test.exe" hidden 26 >"$E/game.out" 2>/dev/null &
game=$!
n=0; until grep -q '^start ' "$E/game.out" 2>/dev/null; do n=$((n + 1)); [ $n -gt 300 ] && break; nap 0.1; done
PROTIUM_RUNTIME=$INSTALL_DIR "$E/Protium" --game-notice 9.9.9 "The first new thing, in a line as long as a line of a changelog gets to be." >"$E/notice.out" 2>&1 &
notice=$!
n=0; until [ -n "$(panel)" ]; do n=$((n + 1)); [ $n -gt 100 ] && break; nap 0.1; done
nap 1
line=$(panel | head -1)
if [ -z "$line" ]; then
    fail shown "no panel of the notice came on screen"
else
    set -- $(echo "$line" | awk -F'\t' '{split($3, at, ","); print at[1], at[2], $4}')
    px=$1 py=$2 layer=$3
    glayer=$("$E/list_windows" "$INSTALL_DIR" | awk -F'\t' '$6 == 1 {split($2, s, "x"); if (s[1] >= 640 && $4 > m) m = $4} END {print m + 0}')
    [ "$layer" -gt "$glayer" ] && pass shown "the panel is at $px,$py on layer $layer, above the game's ($glayer)" \
        || fail shown "the panel's layer $layer is not above the game's $glayer"
    screencapture -x -R"$px,$py,520,88" "$E/during.png"
    front=$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)
    fpath=$(ps -o comm= -p "$front" 2>/dev/null)
    # the notice must not be the application in front. Which one is depends on who uses the Mac
    # meanwhile: the game (Wine names a process after its Windows program) when nobody does
    [ "$front" != "$notice" ] && [ "$(basename "$fpath")" != Protium ] && pass focus "the notice is not in front; $(basename "$fpath") is" \
        || fail focus "the notice took the front: $fpath"
    "$E/mouse_feed" clicks "$((px + 260)),$((py + 44))" >"$E/feed.out" 2>&1
    nap 0.5
    # the game hides the pointer, so Wine says the click is where its own pointer is (the middle),
    # not where the system's was; that it arrived at all is what shows the panel let it through
    tr -d '\r' <"$E/game.out" | grep -q "^click " && pass click "a click at the panel's place arrived in the game" \
        || fail click "the game got no click"
    n=0; while [ -n "$(panel)" ] || kill -0 $notice 2>/dev/null; do n=$((n + 1)); [ $n -gt 150 ] && break; nap 0.1; done
    [ -z "$(panel)" ] && ! kill -0 $notice 2>/dev/null && pass gone "the panel and its process are gone" || fail gone "the notice is still there"
    screencapture -x -R"$px,$py,520,88" "$E/after.png"
    during=$(stat -f %z "$E/during.png"); after=$(stat -f %z "$E/after.png")
    [ "$during" -gt $((after * 2)) ] && pass drawn "a picture while it showed ($during bytes), the game's plain grey after ($after)" \
        || fail drawn "the two pictures are alike: $during and $after bytes"
fi
WINEPREFIX=$PREFIX "$INSTALL_DIR/bin/wineserver" -k >/dev/null 2>&1
wait $game 2>/dev/null
exit $FAILED
