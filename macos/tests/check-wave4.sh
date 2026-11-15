#!/bin/bash
#
# Wave 4 acceptance check for the native arm64 macOS Wine build: graphics. A Windows program
# gets a window and Direct3D on Metal: DXMT for Direct3D 10 and 11, vkd3d-proton on KosmicKrisp
# for Direct3D 12.
#
#   macos/tests/check-wave4.sh
#
# It runs on what Wave 3b builds: the arm64ec + aarch64 Wine with FEX's module, installed with
# its loader in wine.app (see check-wave3b.sh, whose build step this check runs first). Wave 3b
# itself is still open: what is left of it needs the provisioning profile, and this wave was
# started without it.
#
# Items (pass/fail):
#   1  a window through winemac.drv: window_test.exe, built for aarch64 and for x86_64 (which
#      runs through FEX), opens a 320x240 window, paints it and reads the colour back; while it
#      is open macOS lists a window of that size and place that belongs to the loader in
#      wine.app, and none once it has closed. This item opens two small windows on the screen
#      for a few seconds and needs a session with a display.
#   2  regression: check-wave3b.sh has no FAIL (its exit status 3, for what the profile gates,
#      is accepted)
# The build and the test programs come first ("build").
#
# NOT YET CHECKED, so this check passing does not make Wave 4 done: fonts (Wine does not find
# FreeType at run time), Vulkan in Wine with KosmicKrisp, DXMT, vkd3d-proton, and a game. The
# summary lists them as TODO and the exit status is 3 while they are open and nothing failed
# (1 when an item failed, 0 only when all of it passed).
# Logs go to $EVIDENCE_DIR.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
SRC_DIR=${SRC_DIR:-$BUILD_ROOT/wine-src}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave4}
WINEBOOT_TIMEOUT=${WINEBOOT_TIMEOUT:-300}
RUN_TIMEOUT=${RUN_TIMEOUT:-120}
WINDOW_HOLD_MS=${WINDOW_HOLD_MS:-3000}
UNIX_DIR=aarch64-unix
export MIN_FREE_GB=${MIN_FREE_GB:-10}
# A new prefix would otherwise wait on the Mono and Gecko install dialogs.
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
TODO=0
# CHECK_ITEMS limits the run to some items ("build" rebuilds Wine, the bundle and the test programs).
CHECK_ITEMS=${CHECK_ITEMS:-"build 1 2"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
todo() { RESULTS+=("TODO  $1"); echo "TODO  $1"; TODO=1; }
run_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$t" "$@"; }
nap() { perl -e 'select(undef, undef, undef, shift)' "$1"; }

MINGW_BIN=$TOOLCHAIN_DIR/bin
READOBJ=$MINGW_BIN/llvm-readobj
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
INSTALL_DIR=$(cd "${INSTALL_DIR:-/nonexistent}" 2>/dev/null && pwd -P || echo "${INSTALL_DIR:-/nonexistent}")
BUNDLE_LOADER=$INSTALL_DIR/lib/wine/$UNIX_DIR/wine.app/Contents/MacOS/wine
WINE=$INSTALL_DIR/bin/wine
SERVER=$INSTALL_DIR/bin/wineserver
TESTS_OUT=$EVIDENCE_DIR/programs
mkdir -p "$TESTS_OUT"

cleanup_prefix() {
    WINEPREFIX=$1 run_timeout 30 "$SERVER" -k >/dev/null 2>&1
    WINEPREFIX=$1 run_timeout 60 "$SERVER" -w >/dev/null 2>&1
    rm -rf "$1"
}

########################################################################
# Build: Wave 3b's build and bundle, and the test programs
########################################################################
if want build; then
echo "== build: check-wave3b.sh's build step and the test programs"
B3=$EVIDENCE_DIR/wave3b-build
rm -rf "$B3"; mkdir -p "$B3"
EVIDENCE_DIR=$B3 CHECK_ITEMS="build" "$PROTON_DIR/macos/tests/check-wave3b.sh" >"$B3/check-wave3b.out" 2>&1
if [ -s "$B3/check-summary.txt" ] && ! grep -q '^FAIL' "$B3/check-summary.txt" && grep -q '^PASS  item build: bundle-wine.sh' "$B3/check-summary.txt"; then
    pass build "check-wave3b.sh build step: Wine, FEX and the bundle ($B3/check-summary.txt)"
else
    fail build "check-wave3b.sh build step: $(grep '^FAIL' "$B3/check-summary.txt" 2>/dev/null | cut -c1-80 | paste -sd';' -) ($B3)"
fi
# window_test.exe: for aarch64 with the build's own winegcc, in the build's MSVC mode, against
# Wine's CRT; for x86_64 with the mingw compiler and its CRT, like a program from outside Wine
wlog=$TESTS_OUT/window_test.build.log
rm -f "$TESTS_OUT/window_test.exe" "$TESTS_OUT/window_test_x64.exe"
{
    echo "\$ winegcc -b aarch64-windows window_test.c (Wine CRT)"
    libs=""
    for l in user32 gdi32 winecrt0 ucrtbase kernel32 ntdll; do libs="$libs $BUILD_DIR/dlls/$l/aarch64-windows/lib$l.a"; done
    # shellcheck disable=SC2086
    PATH=$MINGW_BIN:$PATH "$BUILD_DIR/tools/winegcc/winegcc" -v --wine-objdir "$BUILD_DIR" -b aarch64-windows \
        -mconsole -O2 -Wall -D_UCRT -I"$SRC_DIR/include/msvcrt" -I"$SRC_DIR/include" \
        -o "$TESTS_OUT/window_test.exe" "$SCRIPT_DIR/window_test.c" $libs
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/window_test.exe" | grep -E 'Format|Machine'
    echo "\$ x86_64-w64-mingw32-clang window_test.c"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/window_test_x64.exe" "$SCRIPT_DIR/window_test.c" -luser32 -lgdi32
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/window_test_x64.exe" | grep -E 'Format|Machine'
} >"$wlog" 2>&1
if [ -f "$TESTS_OUT/window_test.exe" ] && [ -f "$TESTS_OUT/window_test_x64.exe" ] &&
   grep -q '^Format: COFF-ARM64$' "$wlog" && grep -q '^Format: COFF-x86-64$' "$wlog"; then
    pass build "window_test.exe built, COFF-ARM64 and COFF-x86-64 ($wlog)"
else
    fail build "window_test.exe did not build for both architectures ($wlog)"
fi
llog=$TESTS_OUT/list_windows.build.log
rm -f "$TESTS_OUT/list_windows"
clang -O1 -Wall -Werror -o "$TESTS_OUT/list_windows" "$SCRIPT_DIR/list_windows.c" -framework CoreGraphics -framework CoreFoundation >"$llog" 2>&1
if [ -x "$TESTS_OUT/list_windows" ]; then pass build "list_windows built ($llog)"; else fail build "list_windows did not build ($llog)"; fi
fi  # build

########################################################################
# Item 1: a window through winemac.drv
########################################################################
if want 1; then
echo "== item 1: a window through winemac.drv, aarch64 and x86_64"
wdir=$EVIDENCE_DIR/item1-window
rm -rf "$wdir"; mkdir -p "$wdir"
PREFIX=$BUILD_ROOT/wave4-prefix-window
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
WINDOW_LINE='window: driver winemac.drv, screen [0-9]+x[0-9]+, 320x240 at 120,120, painted 1, pixel 563412, visible 1'
# the window as macOS has to list it: its size, its place, and the loader in wine.app as its owner
MAC_WINDOW=$(printf '\t320x240\t120,120\t[0-9-]+\t%s$' "$BUNDLE_LOADER")
# set the prefix up first, so that the timed runs only show the window
WINEPREFIX=$PREFIX run_timeout "$WINEBOOT_TIMEOUT" "$WINE" "$TESTS_OUT/window_test.exe" 0 >"$wdir/setup.stdout" 2>"$wdir/setup.stderr"
echo "prefix setup: exit=$? $(tr -d '\r' <"$wdir/setup.stdout")" >>"$wdir/summary.txt"
wpass=0
for p in window_test window_test_x64; do
    WINEPREFIX=$PREFIX run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/$p.exe" "$WINDOW_HOLD_MS" >"$wdir/$p.stdout" 2>"$wdir/$p.stderr" &
    wpid=$!
    # the program prints its line once the window is painted, and then keeps it open
    for i in $(seq 1 120); do [ -s "$wdir/$p.stdout" ] && break; nap 0.25; done
    "$TESTS_OUT/list_windows" "$INSTALL_DIR" >"$wdir/$p.mac-open.txt" 2>&1
    wait $wpid
    rc=$?
    WINEPREFIX=$PREFIX run_timeout 60 "$SERVER" -w >/dev/null 2>&1
    "$TESTS_OUT/list_windows" "$INSTALL_DIR" >"$wdir/$p.mac-closed.txt" 2>&1
    line=no; tr -d '\r' <"$wdir/$p.stdout" | grep -Eqx "$WINDOW_LINE" && line=yes
    open=$(grep -c -E "$MAC_WINDOW" "$wdir/$p.mac-open.txt")
    closed=$(grep -c -E "$MAC_WINDOW" "$wdir/$p.mac-closed.txt")
    [ "$rc" = 0 ] && [ $line = yes ] && [ "$open" = 1 ] && [ "$closed" = 0 ] && wpass=$((wpass + 1))
    echo "$p.exe: exit=$rc line=$line ($(tr -d '\r' <"$wdir/$p.stdout" | head -1)); macOS lists the window while open: $open, after: $closed" >>"$wdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$wpass" = 2 ]; then
    pass 1 "window_test.exe (aarch64) and window_test_x64.exe (x86_64) opened, painted and read back a 320x240 window through winemac.drv, and macOS listed it for the loader in wine.app while it was open ($wdir/summary.txt)"
else
    fail 1 "$wpass of 2 window tests passed ($wdir/summary.txt)"
fi
fi  # item 1

########################################################################
# Item 2: regression of Wave 3b
########################################################################
if want 2; then
echo "== item 2: Wave 3b regression"
R=$EVIDENCE_DIR/regression-wave3b
rm -rf "$R"; mkdir -p "$R"
EVIDENCE_DIR=$R "$PROTON_DIR/macos/tests/check-wave3b.sh" >"$R/check-wave3b.out" 2>&1
rrc=$?
# 3 is its status while only its TODO line, what the provisioning profile gates, is open
if { [ $rrc = 0 ] || [ $rrc = 3 ]; } && [ -s "$R/check-summary.txt" ] && ! grep -q '^FAIL' "$R/check-summary.txt"; then
    pass 2 "check-wave3b.sh: exit $rrc, no FAIL ($R/check-summary.txt)"
else
    fail 2 "check-wave3b.sh exit $rrc: $(grep '^FAIL' "$R/check-summary.txt" 2>/dev/null | cut -c1-70 | paste -sd';' -) ($R)"
fi
fi  # item 2

todo "fonts (FreeType is not found at run time), Vulkan in Wine with KosmicKrisp, DXMT, vkd3d-proton and a game have no items yet; Wave 4 is not done"

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
[ $FAILED = 0 ] || exit 1
[ $TODO = 0 ] || exit 3
exit 0
