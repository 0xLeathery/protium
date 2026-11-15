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
#   3  TrueType fonts: font_test.exe, for aarch64 and for x86_64, gets Wine's Tahoma as a
#      TrueType font with glyph outlines, draws a word with it and is listed TrueType families;
#      Wine does not say that it cannot find FreeType, which the bundle now carries in
#      lib/external with the Homebrew libraries it needs
#   4  the Vulkan loader from Windows code: vulkan_test.exe, for aarch64 and for x86_64, loads
#      vulkan-1.dll and gets the host loader's version (1.3 or later) through winevulkan, and
#      Wine does not say that it has no Vulkan. There is no Vulkan driver yet: creating an
#      instance gives VK_ERROR_INCOMPATIBLE_DRIVER, and the item wants the host loader's own
#      "Found no drivers" then, which shows that it is the one that answered
# The build and the test programs come first ("build").
#
# NOT YET CHECKED, so this check passing does not make Wave 4 done: a Vulkan driver
# (KosmicKrisp), DXMT, vkd3d-proton, and a game. The summary lists them as TODO and the exit
# status is 3 while they are open and nothing failed (1 when an item failed, 0 only when all of
# it passed).
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
CHECK_ITEMS=${CHECK_ITEMS:-"build 1 2 3 4"}
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
# Proton's wineserver starts to shut down the moment its last process exits (server/main.c sets
# master_socket_timeout to 0, where Wine's own default is 3 seconds). A wine that starts right
# after another one has exited then meets a server that is going away: it brings Wine's
# services up again, and now and then it is dropped while the server exits, which ends it with
# status 0 and no output. For a run of launches in one prefix, hold_server starts a server that
# waits 10 seconds for the next process instead; cleanup_prefix ends it.
hold_server() { WINEPREFIX=$1 run_timeout 30 "$SERVER" -p10 >/dev/null 2>&1; }

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
# The GUI test programs: for aarch64 with the build's own winegcc, in the build's MSVC mode,
# against Wine's CRT; for x86_64 with the mingw compiler and its CRT, like a program from
# outside Wine
build_gui_program() {
    local name=$1 log=$TESTS_OUT/$1.build.log libs="" l
    rm -f "$TESTS_OUT/$name.exe" "$TESTS_OUT/${name}_x64.exe"
    {
        echo "\$ winegcc -b aarch64-windows $name.c (Wine CRT)"
        for l in user32 gdi32 winecrt0 ucrtbase kernel32 ntdll; do libs="$libs $BUILD_DIR/dlls/$l/aarch64-windows/lib$l.a"; done
        # shellcheck disable=SC2086
        PATH=$MINGW_BIN:$PATH "$BUILD_DIR/tools/winegcc/winegcc" -v --wine-objdir "$BUILD_DIR" -b aarch64-windows \
            -mconsole -O2 -Wall -D_UCRT -I"$SRC_DIR/include/msvcrt" -I"$SRC_DIR/include" \
            -o "$TESTS_OUT/$name.exe" "$SCRIPT_DIR/$name.c" $libs
        echo "exit=$?"
        "$READOBJ" --file-headers "$TESTS_OUT/$name.exe" | grep -E 'Format|Machine'
        echo "\$ x86_64-w64-mingw32-clang $name.c"
        "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/${name}_x64.exe" "$SCRIPT_DIR/$name.c" -luser32 -lgdi32
        echo "exit=$?"
        "$READOBJ" --file-headers "$TESTS_OUT/${name}_x64.exe" | grep -E 'Format|Machine'
    } >"$log" 2>&1
    [ -f "$TESTS_OUT/$name.exe" ] && [ -f "$TESTS_OUT/${name}_x64.exe" ] &&
        grep -q '^Format: COFF-ARM64$' "$log" && grep -q '^Format: COFF-x86-64$' "$log"
}
for p in window_test font_test vulkan_test; do
    if build_gui_program $p; then
        pass build "$p.exe built, COFF-ARM64 and COFF-x86-64 ($TESTS_OUT/$p.build.log)"
    else
        fail build "$p.exe did not build for both architectures ($TESTS_OUT/$p.build.log)"
    fi
done
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
# each launch of this item waits for the session before it to end (see hold_server): macOS is
# asked for the window list once Wine is gone
WINEPREFIX=$PREFIX run_timeout 60 "$SERVER" -w >/dev/null 2>&1
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

########################################################################
# Item 3: TrueType fonts
########################################################################
if want 3; then
echo "== item 3: TrueType fonts, aarch64 and x86_64"
fdir=$EVIDENCE_DIR/item3-fonts
rm -rf "$fdir"; mkdir -p "$fdir"
PREFIX=$BUILD_ROOT/wave4-prefix-font
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
FONT_LINE='font: face Tahoma, truetype 1, outline 1, drawn pixels [1-9][0-9]*, truetype families [1-9][0-9]*'
fpass=0; t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up and makes the font list
for p in font_test font_test_x64; do
    WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/$p.exe" >"$fdir/$p.stdout" 2>"$fdir/$p.stderr"
    rc=$?
    t=$RUN_TIMEOUT
    line=no; tr -d '\r' <"$fdir/$p.stdout" | grep -Eqx "$FONT_LINE" && line=yes
    nft=$(grep -c 'cannot find the FreeType font library' "$fdir/$p.stderr")
    [ "$rc" = 0 ] && [ $line = yes ] && [ "$nft" = 0 ] && fpass=$((fpass + 1))
    echo "$p.exe: exit=$rc line=$line ($(tr -d '\r' <"$fdir/$p.stdout" | head -1)); 'cannot find the FreeType font library' messages: $nft" >>"$fdir/summary.txt"
done
cleanup_prefix "$PREFIX"
ext=$INSTALL_DIR/lib/external
{ echo "lib/external:"; ls -l "$ext" 2>&1; ls -l "$INSTALL_DIR/lib/wine/$UNIX_DIR/libfreetype.6.dylib" 2>&1; } >>"$fdir/summary.txt"
extok=yes
[ -f "$ext/libfreetype.6.dylib" ] && codesign --verify "$ext/libfreetype.6.dylib" 2>/dev/null || extok=no
if [ "$fpass" = 2 ] && [ $extok = yes ]; then
    pass 3 "font_test.exe (aarch64) and font_test_x64.exe (x86_64) got Tahoma as a TrueType font and drew with it; FreeType is in lib/external and Wine found it ($fdir/summary.txt)"
else
    fail 3 "$fpass of 2 font tests passed, FreeType bundled and signed: $extok ($fdir/summary.txt)"
fi
fi  # item 3

########################################################################
# Item 4: the Vulkan loader from Windows code
########################################################################
if want 4; then
echo "== item 4: the Vulkan loader from Windows code, aarch64 and x86_64"
vdir=$EVIDENCE_DIR/item4-vulkan
rm -rf "$vdir"; mkdir -p "$vdir"
PREFIX=$BUILD_ROOT/wave4-prefix-vulkan
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
VULKAN_LINE='vulkan: loader 1\.([3-9]|[1-9][0-9])\.[0-9]+, instance (0|-9), devices [0-9]+(, first device .*)?'
vpass=0; t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
for p in vulkan_test vulkan_test_x64; do
    WINEPREFIX=$PREFIX VK_LOADER_DEBUG=error,warn run_timeout "$t" "$WINE" "$TESTS_OUT/$p.exe" >"$vdir/$p.stdout" 2>"$vdir/$p.stderr"
    rc=$?
    t=$RUN_TIMEOUT
    out=$(tr -d '\r' <"$vdir/$p.stdout" | head -1)
    line=no; echo "$out" | grep -Eqx "$VULKAN_LINE" && line=yes
    res=$(echo "$out" | sed -n 's/.*, instance \(-\{0,1\}[0-9]*\), devices.*/\1/p')
    nwine=$(grep -a -c -E 'built without Vulkan support|Failed to load libvulkan|Failed to load Wine graphics driver supporting Vulkan' "$vdir/$p.stderr")
    nhost=$(grep -a -c 'Vulkan Loader.*Found no drivers' "$vdir/$p.stderr")
    # without a driver, the host loader has to be the one that said so
    answered=yes; [ "$res" = 0 ] || [ "$nhost" -ge 1 ] || answered=no
    [ "$rc" = 0 ] && [ $line = yes ] && [ "$nwine" = 0 ] && [ $answered = yes ] && vpass=$((vpass + 1))
    echo "$p.exe: exit=$rc line=$line ($out); Wine's no-Vulkan messages: $nwine; host loader's 'Found no drivers': $nhost" >>"$vdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$vpass" = 2 ]; then
    pass 4 "vulkan_test.exe (aarch64) and vulkan_test_x64.exe (x86_64) reached the host Vulkan loader through vulkan-1.dll: '$out' ($vdir/summary.txt)"
else
    fail 4 "$vpass of 2 Vulkan tests passed ($vdir/summary.txt)"
fi
fi  # item 4

todo "a Vulkan driver (KosmicKrisp), DXMT, vkd3d-proton and a game have no items yet; Wave 4 is not done"

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
[ $FAILED = 0 ] || exit 1
[ $TODO = 0 ] || exit 3
exit 0
