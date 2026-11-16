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
#      is open the window server has a window of that size and place that belongs to the loader
#      in wine.app, and none once it has closed. This item opens two small windows for a few
#      seconds and needs a session with a display. The window need not be on screen: it is not
#      while the user is in another Space, such as a full screen app.
#   2  regression: check-wave3b.sh has no FAIL (its exit status 3, for what the profile gates,
#      is accepted)
#   3  TrueType fonts: font_test.exe, for aarch64 and for x86_64, gets Wine's Tahoma as a
#      TrueType font with glyph outlines, draws a word with it and is listed TrueType families;
#      Wine does not say that it cannot find FreeType, which the bundle now carries in
#      lib/external with the Homebrew libraries it needs
#   4  a Vulkan device from Windows code: vulkan_test.exe, for aarch64 and for x86_64, loads
#      vulkan-1.dll, gets the host loader's version (1.3 or later) through winevulkan, creates
#      an instance and is given at least one device. The host loader reads the manifest of the
#      driver that the install carries (KosmicKrisp, in share/vulkan/icd.d, which ntdll names
#      to it) and no other manifest, and Wine does not say that it has no Vulkan
#   5  Direct3D 11 through DXMT, off screen: d3d11_test_x64.exe, an x86_64 program, gets a
#      hardware device of feature level 11_0 or more from DXMT (winemetal.dll is in the
#      process), compiles two HLSL shaders, draws into a texture and reads back the colour it
#      drew, D3D_RUNS runs. No window is involved.
#   6  Direct3D 11 in a window: d3d11_window_test_x64.exe, an x86_64 program, gets a swap chain
#      on its own 640x360 window from DXMT, through the macdrv_functions table that winemac.drv
#      exports, and every Present() of D3D_FRAMES frames succeeds with the back buffer the
#      colour it was cleared to; the window server has the window meanwhile. This shows the
#      path up to the hand-over of each frame, not that the frame is on the screen: nothing
#      here may read the screen.
#   7  other targets unchanged: every line of this wave in Wine is under __APPLE__ && __aarch64__
#      (with either undefined the files are the wave base text); diff scope
#   8  audio output: audio_test_x64.exe, an x86_64 program, finds an output device, opens it
#      at 48 kHz 16 bit stereo through winmm and Wine's CoreAudio driver, and the device plays
#      300 ms of silence to the end, AUDIO_RUNS runs. Nothing is heard.
#   9  Direct3D 12 through vkd3d-proton, off screen: d3d12_test_x64.exe, an x86_64 program,
#      gets a device from vkd3d-proton (its d3d12core.dll is in the process) on the adapter of
#      DXMT's dxgi, compiles two HLSL shaders, makes a pipeline state from them, draws into a
#      texture and reads back the colour it drew, D3D_RUNS runs. vkd3d-proton reaches the GPU
#      through Wine's Vulkan and the install's KosmicKrisp. No window is involved.
#  10  Direct3D 12 in a window: d3d12_window_test_x64.exe, an x86_64 program, gets a flip-model
#      swap chain on its own 640x360 window from DXMT's dxgi and vkd3d-proton, which says that
#      it creates one of that size, and every Present() of D3D_FRAMES frames succeeds with the
#      last back buffer the colour it was cleared to; the window server has the window
#      meanwhile. The frames go through Wine's Vulkan surface for the window (winemac.drv) and
#      KosmicKrisp. As in item 6, that the frame is on the screen is not shown.
#  11  a real program: the Godot editor for Windows, which macos/tests/fetch-godot.sh downloads
#      (a TODO while it is not there). Its native arm64 build runs the project manager for
#      GODOT_FRAMES frames and exits 0, once on its Vulkan renderer and once on its Direct3D
#      12 renderer, and says for each that it uses device 0. Its x86_64 build has to do the
#      same on Vulkan when there is a profile. Without one it gets a device and then hangs or
#      crashes before its first frame, and is a TODO, not a pass: one cause is known (FEX's
#      guard pages need 4K pages, check-wave3b.sh item 9), and whether it is the only one
#      cannot be told while that one is there. This item opens the editor's window three
#      times for some seconds.
# The build and the test programs come first ("build").
#
# Items 1, 6, 8 and 10 need the screen unlocked. While it is locked the window server reports
# every window scaled down and moved (a 640x360 window at 160,160 as 577x325 at 219,193), and
# the audio output takes the first 100 ms and then stalls. They fail then, without being run,
# and say why.
#
# NOT YET CHECKED, so this check passing does not make Wave 4 done: that Direct3D 11 frames are
# on the screen, which only someone looking can tell (DXMT has its own way into the window, the
# metal view of item 6), that a window's picture follows it when it is resized, and a game.
# What goes through Wine's Vulkan surface, Vulkan and Direct3D 12, has been seen: on 2026-11-16
# the user watched the Godot editor of item 11 open and run during a run of this check. The
# summary lists the rest as TODO and the exit status is 3 while it is open and nothing failed
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
D3D_RUNS=${D3D_RUNS:-5}
D3D_FRAMES=${D3D_FRAMES:-180}
AUDIO_RUNS=${AUDIO_RUNS:-3}
GODOT_DIR=${GODOT_DIR:-$BUILD_ROOT/third-party/godot-4.7.2-stable}
GODOT_FRAMES=${GODOT_FRAMES:-600}
GODOT_X64_TIMEOUT=${GODOT_X64_TIMEOUT:-90}
LOADER_PROFILE=${LOADER_PROFILE:-}
WINE_DIR=$PROTON_DIR/wine
# wine and superproject commits this wave starts from (the tips after Wave 3b's last change)
WINE_WAVE_BASE=${WINE_WAVE_BASE:-367c1ae9b0468f5d8b60b32be12cefe91eba0ffb}
SUPER_WAVE_BASE=${SUPER_WAVE_BASE:-acfe76e00fbbbf49b10ef781d58e2bfdabb76ec5}
# Wine files this wave may change: winemac.drv's table for DXMT, where ntdll tells the Vulkan
# loader to look for drivers, and what stopped real programs: ntdll's start of a 32-bit
# process, and uiautomationcore's use of results that a provider did not set. virtual.c is
# Wave 3b's: its work for the provisioning profile was done after this wave had begun.
WAVE_FILES="dlls/winemac.drv/macdrv.h dlls/winemac.drv/window.c dlls/ntdll/unix/loader.c dlls/uiautomationcore/uia_client.c dlls/ntdll/unix/virtual.c"
UNIX_DIR=aarch64-unix
export MIN_FREE_GB=${MIN_FREE_GB:-10}
# A new prefix would otherwise wait on the Mono and Gecko install dialogs.
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}
# ntdll leaves the Vulkan loader to the caller when one of these is set; the check is of the
# driver the install carries.
unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
TODO=0
# CHECK_ITEMS limits the run to some items ("build" rebuilds Wine, the bundle and the test programs).
CHECK_ITEMS=${CHECK_ITEMS:-"build 1 2 3 4 5 6 7 8 9 10 11"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
todo() { RESULTS+=("TODO  $1"); echo "TODO  $1"; TODO=1; }
# run_timeout SECONDS cmd...: the command's exit status, or 142 when it ran out of time. The
# command runs as a child that is killed with SIGKILL then: an alarm in the command's own
# process is not enough, an x86_64 program that spins in an exception loop under FEX lived on
# for minutes past one.
run_timeout() {
    local t=$1; shift
    perl -e 'my $t = shift; my $pid = fork; die "fork: $!" unless defined $pid;
             if (!$pid) { exec @ARGV or die "exec: $!" }
             $SIG{ALRM} = sub { kill "KILL", $pid }; alarm $t; waitpid $pid, 0;
             exit((($? & 127) == 9) ? 142 : ($? & 127) ? 128 + ($? & 127) : $? >> 8)' "$t" "$@"
}
nap() { perl -e 'select(undef, undef, undef, shift)' "$1"; }
# needs_unlocked ITEM: fail the item, and return 1, when the screen is locked
needs_unlocked() {
    ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes' || return 0
    fail "$1" "not checked: the screen is locked. The window server then reports every window scaled down and moved, and the audio output stalls; unlock the screen and run this item again"
    return 1
}

MINGW_BIN=$TOOLCHAIN_DIR/bin
READOBJ=$MINGW_BIN/llvm-readobj
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
INSTALL_DIR=$(cd "${INSTALL_DIR:-/nonexistent}" 2>/dev/null && pwd -P || echo "${INSTALL_DIR:-/nonexistent}")
BUNDLE_LOADER=$INSTALL_DIR/lib/wine/$UNIX_DIR/wine.app/Contents/MacOS/wine
WINE=$INSTALL_DIR/bin/wine
SERVER=$INSTALL_DIR/bin/wineserver
TESTS_OUT=$EVIDENCE_DIR/programs
mkdir -p "$TESTS_OUT"
WORK=$EVIDENCE_DIR/work
mkdir -p "$WORK"

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
# d3d11_test_x64.exe: x86_64 only, with the mingw compiler and its Direct3D import libraries
dlog=$TESTS_OUT/d3d11_test_x64.build.log
rm -f "$TESTS_OUT/d3d11_test_x64.exe"
{
    echo "\$ x86_64-w64-mingw32-clang d3d11_test.c -ld3d11 -ld3dcompiler_47 -ldxguid -luuid"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/d3d11_test_x64.exe" "$SCRIPT_DIR/d3d11_test.c" \
        -ld3d11 -ld3dcompiler_47 -ldxguid -luuid
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/d3d11_test_x64.exe" | grep -E 'Format|Machine'
} >"$dlog" 2>&1
if [ -f "$TESTS_OUT/d3d11_test_x64.exe" ] && grep -q '^Format: COFF-x86-64$' "$dlog"; then pass build "d3d11_test_x64.exe built, COFF-x86-64 ($dlog)"; else fail build "d3d11_test_x64.exe did not build as COFF-x86-64 ($dlog)"; fi
dwlog=$TESTS_OUT/d3d11_window_test_x64.build.log
rm -f "$TESTS_OUT/d3d11_window_test_x64.exe"
{
    echo "\$ x86_64-w64-mingw32-clang d3d11_window_test.c -ld3d11 -ldxguid -luuid -luser32"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/d3d11_window_test_x64.exe" "$SCRIPT_DIR/d3d11_window_test.c" \
        -ld3d11 -ldxguid -luuid -luser32
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/d3d11_window_test_x64.exe" | grep -E 'Format|Machine'
} >"$dwlog" 2>&1
if [ -f "$TESTS_OUT/d3d11_window_test_x64.exe" ] && grep -q '^Format: COFF-x86-64$' "$dwlog"; then pass build "d3d11_window_test_x64.exe built, COFF-x86-64 ($dwlog)"; else fail build "d3d11_window_test_x64.exe did not build as COFF-x86-64 ($dwlog)"; fi
d12log=$TESTS_OUT/d3d12_test_x64.build.log
rm -f "$TESTS_OUT/d3d12_test_x64.exe"
{
    echo "\$ x86_64-w64-mingw32-clang d3d12_test.c -ld3d12 -ldxgi -ld3dcompiler_47 -ldxguid -luuid"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/d3d12_test_x64.exe" "$SCRIPT_DIR/d3d12_test.c" \
        -ld3d12 -ldxgi -ld3dcompiler_47 -ldxguid -luuid
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/d3d12_test_x64.exe" | grep -E 'Format|Machine'
} >"$d12log" 2>&1
if [ -f "$TESTS_OUT/d3d12_test_x64.exe" ] && grep -q '^Format: COFF-x86-64$' "$d12log"; then pass build "d3d12_test_x64.exe built, COFF-x86-64 ($d12log)"; else fail build "d3d12_test_x64.exe did not build as COFF-x86-64 ($d12log)"; fi
d12wlog=$TESTS_OUT/d3d12_window_test_x64.build.log
rm -f "$TESTS_OUT/d3d12_window_test_x64.exe"
{
    echo "\$ x86_64-w64-mingw32-clang d3d12_window_test.c -ld3d12 -ldxgi -ldxguid -luuid -luser32"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/d3d12_window_test_x64.exe" "$SCRIPT_DIR/d3d12_window_test.c" \
        -ld3d12 -ldxgi -ldxguid -luuid -luser32
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/d3d12_window_test_x64.exe" | grep -E 'Format|Machine'
} >"$d12wlog" 2>&1
if [ -f "$TESTS_OUT/d3d12_window_test_x64.exe" ] && grep -q '^Format: COFF-x86-64$' "$d12wlog"; then pass build "d3d12_window_test_x64.exe built, COFF-x86-64 ($d12wlog)"; else fail build "d3d12_window_test_x64.exe did not build as COFF-x86-64 ($d12wlog)"; fi
alog=$TESTS_OUT/audio_test_x64.build.log
rm -f "$TESTS_OUT/audio_test_x64.exe"
{
    echo "\$ x86_64-w64-mingw32-clang audio_test.c -lwinmm"
    "$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -o "$TESTS_OUT/audio_test_x64.exe" "$SCRIPT_DIR/audio_test.c" -lwinmm
    echo "exit=$?"
    "$READOBJ" --file-headers "$TESTS_OUT/audio_test_x64.exe" | grep -E 'Format|Machine'
} >"$alog" 2>&1
if [ -f "$TESTS_OUT/audio_test_x64.exe" ] && grep -q '^Format: COFF-x86-64$' "$alog"; then pass build "audio_test_x64.exe built, COFF-x86-64 ($alog)"; else fail build "audio_test_x64.exe did not build as COFF-x86-64 ($alog)"; fi
llog=$TESTS_OUT/list_windows.build.log
rm -f "$TESTS_OUT/list_windows"
clang -O1 -Wall -Werror -o "$TESTS_OUT/list_windows" "$SCRIPT_DIR/list_windows.c" -framework CoreGraphics -framework CoreFoundation >"$llog" 2>&1
if [ -x "$TESTS_OUT/list_windows" ]; then pass build "list_windows built ($llog)"; else fail build "list_windows did not build ($llog)"; fi
fi  # build

########################################################################
# Item 1: a window through winemac.drv
########################################################################
if want 1 && needs_unlocked 1; then
echo "== item 1: a window through winemac.drv, aarch64 and x86_64"
wdir=$EVIDENCE_DIR/item1-window
rm -rf "$wdir"; mkdir -p "$wdir"
PREFIX=$BUILD_ROOT/wave4-prefix-window
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
WINDOW_LINE='window: driver winemac.drv, screen [0-9]+x[0-9]+, 320x240 at 120,120, painted 1, pixel 563412, visible 1'
# the window as the window server has to list it: its size, its place, and the loader in
# wine.app as its owner; the last column says whether it is on screen, which is not asked for
MAC_WINDOW=$(printf '\t320x240\t120,120\t[0-9-]+\t%s\t[01]$' "$BUNDLE_LOADER")
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
    onscreen=$(grep -E "$MAC_WINDOW" "$wdir/$p.mac-open.txt" | grep -c "$(printf '\t1$')")
    [ "$rc" = 0 ] && [ $line = yes ] && [ "$open" = 1 ] && [ "$closed" = 0 ] && wpass=$((wpass + 1))
    echo "$p.exe: exit=$rc line=$line ($(tr -d '\r' <"$wdir/$p.stdout" | head -1)); the window server has the window while open: $open (on screen: $onscreen), after: $closed" >>"$wdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$wpass" = 2 ]; then
    pass 1 "window_test.exe (aarch64) and window_test_x64.exe (x86_64) opened, painted and read back a 320x240 window through winemac.drv, and the window server had it for the loader in wine.app while it was open ($wdir/summary.txt)"
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
# Item 4: a Vulkan device from Windows code
########################################################################
if want 4; then
echo "== item 4: a Vulkan device from Windows code, aarch64 and x86_64"
vdir=$EVIDENCE_DIR/item4-vulkan
rm -rf "$vdir"; mkdir -p "$vdir"
PREFIX=$BUILD_ROOT/wave4-prefix-vulkan
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
VULKAN_LINE='vulkan: loader 1\.([3-9]|[1-9][0-9])\.[0-9]+, instance 0, devices [1-9][0-9]*, first device "[^"]+" api 1\.[0-9]+\.[0-9]+'
OWN_ICD=$(realpath "$INSTALL_DIR/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json" 2>/dev/null)
vpass=0; t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
for p in vulkan_test vulkan_test_x64; do
    WINEPREFIX=$PREFIX VK_LOADER_DEBUG=error,warn,driver run_timeout "$t" "$WINE" "$TESTS_OUT/$p.exe" >"$vdir/$p.stdout" 2>"$vdir/$p.stderr"
    rc=$?
    t=$RUN_TIMEOUT
    out=$(tr -d '\r' <"$vdir/$p.stdout" | head -1)
    line=no; echo "$out" | grep -Eqx "$VULKAN_LINE" && line=yes
    nwine=$(grep -a -c -E 'built without Vulkan support|Failed to load libvulkan|Failed to load Wine graphics driver supporting Vulkan' "$vdir/$p.stderr")
    nhost=$(grep -a -c 'Vulkan Loader.*Found no drivers' "$vdir/$p.stderr")
    # the manifests the host loader read: the install's own, and none from anywhere else
    # (ntdll names the directory relative to its own, so the paths are compared resolved)
    nown=0; nother=0
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        if [ -n "$OWN_ICD" ] && [ "$(realpath "$m" 2>/dev/null)" = "$OWN_ICD" ]; then nown=$((nown + 1)); else nother=$((nother + 1)); fi
    done <<EOF
$(grep -a 'Vulkan Loader.*Found ICD manifest file ' "$vdir/$p.stderr" | sed 's/.*Found ICD manifest file \(.*\), version .*/\1/')
EOF
    [ "$rc" = 0 ] && [ $line = yes ] && [ "$nwine" = 0 ] && [ "$nhost" = 0 ] && [ "$nown" -ge 1 ] && [ "$nother" = 0 ] && vpass=$((vpass + 1))
    echo "$p.exe: exit=$rc line=$line ($out); Wine's no-Vulkan messages: $nwine; host loader's 'Found no drivers': $nhost; it read the install's KosmicKrisp manifest $nown times and $nother other manifests" >>"$vdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$vpass" = 2 ]; then
    pass 4 "vulkan_test.exe (aarch64) and vulkan_test_x64.exe (x86_64) got a device from the install's KosmicKrisp through vulkan-1.dll: '$out' ($vdir/summary.txt)"
else
    fail 4 "$vpass of 2 Vulkan tests passed ($vdir/summary.txt)"
fi
fi  # item 4

########################################################################
# Item 5: Direct3D 11 through DXMT, off screen
########################################################################
if want 5; then
echo "== item 5: Direct3D 11 through DXMT, off screen, x86_64 x $D3D_RUNS"
ddir=$EVIDENCE_DIR/item5-d3d11
rm -rf "$ddir"; mkdir -p "$ddir"
PREFIX=$BUILD_ROOT/wave4-prefix-d3d11
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
D3D_LINE='d3d11: dxmt 1, adapter "[^"]+", feature level [bc][01]00, pixel [0-9a-f]{8}, expected 4080bfff'
dpass=0; t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
for i in $(seq 1 "$D3D_RUNS"); do
    WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/d3d11_test_x64.exe" >"$ddir/run$i.stdout" 2>"$ddir/run$i.stderr"
    rc=$?
    t=$RUN_TIMEOUT
    out=$(tr -d '\r' <"$ddir/run$i.stdout" | head -1)
    line=no; echo "$out" | grep -Eqx "$D3D_LINE" && line=yes
    [ "$rc" = 0 ] && [ $line = yes ] && dpass=$((dpass + 1))
    echo "run $i: exit=$rc line=$line ($out)" >>"$ddir/summary.txt"
done
cleanup_prefix "$PREFIX"
{ echo "DXMT in the install tree:"; ls -l "$INSTALL_DIR/lib/wine/aarch64-windows/d3d11.dll" "$INSTALL_DIR/lib/wine/aarch64-windows/winemetal.dll" "$INSTALL_DIR/lib/wine/$UNIX_DIR/winemetal.so" 2>&1; } >>"$ddir/summary.txt"
if [ "$dpass" = "$D3D_RUNS" ]; then
    pass 5 "d3d11_test_x64.exe drew into a texture with DXMT and read its colour back in $dpass/$D3D_RUNS runs: '$out' ($ddir/summary.txt)"
else
    fail 5 "d3d11_test_x64.exe passed $dpass/$D3D_RUNS runs: '$out' ($ddir/summary.txt)"
fi
fi  # item 5

########################################################################
# Item 6: Direct3D 11 in a window
########################################################################
if want 6 && needs_unlocked 6; then
echo "== item 6: Direct3D 11 swap chain in a window, x86_64, $D3D_FRAMES frames"
sdir=$EVIDENCE_DIR/item6-d3d11-window
rm -rf "$sdir"; mkdir -p "$sdir"
PREFIX=$BUILD_ROOT/wave4-prefix-d3d11-window
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
# set the prefix up first and wait for that session to end, so that the timed run is alone
WINEPREFIX=$PREFIX run_timeout "$WINEBOOT_TIMEOUT" "$WINE" "$TESTS_OUT/d3d11_window_test_x64.exe" 2 >"$sdir/setup.stdout" 2>"$sdir/setup.stderr"
echo "prefix setup: exit=$? $(tr -d '\r' <"$sdir/setup.stdout")" >>"$sdir/summary.txt"
WINEPREFIX=$PREFIX run_timeout 60 "$SERVER" -w >/dev/null 2>&1
SWAP_LINE="d3d11 window: dxmt 1, swap chain 0, 640x360, presented $D3D_FRAMES/$D3D_FRAMES, back buffer [0-9a-f]{6}"
D3D_WINDOW=$(printf '\t640x360\t160,160\t[0-9-]+\t%s\t[01]$' "$BUNDLE_LOADER")
WINEPREFIX=$PREFIX run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/d3d11_window_test_x64.exe" "$D3D_FRAMES" >"$sdir/run.stdout" 2>"$sdir/run.stderr" &
spid=$!
# the frames take a few seconds at the display's rate; ask the window server while they run
nopen=0
for i in $(seq 1 40); do
    nap 0.25
    nopen=$("$TESTS_OUT/list_windows" "$INSTALL_DIR" 2>/dev/null | tee "$sdir/mac-open.txt" | grep -c -E "$D3D_WINDOW")
    [ "$nopen" -ge 1 ] && break
    kill -0 $spid 2>/dev/null || break
done
wait $spid
rc=$?
WINEPREFIX=$PREFIX run_timeout 60 "$SERVER" -w >/dev/null 2>&1
out=$(tr -d '\r' <"$sdir/run.stdout" | head -1)
line=no; echo "$out" | grep -Eqx "$SWAP_LINE" && line=yes
nview=$(grep -a -c 'Failed to create metal view' "$sdir/run.stderr")
echo "run: exit=$rc line=$line ($out); the window server had the window while it ran: $nopen; DXMT's 'Failed to create metal view': $nview" >>"$sdir/summary.txt"
cleanup_prefix "$PREFIX"
if [ "$rc" = 0 ] && [ $line = yes ] && [ "$nopen" -ge 1 ] && [ "$nview" = 0 ]; then
    pass 6 "d3d11_window_test_x64.exe got a swap chain on its window from DXMT and presented every frame: '$out' ($sdir/summary.txt)"
else
    fail 6 "exit $rc, line $line: '$out'; window listed $nopen; 'Failed to create metal view' $nview ($sdir/summary.txt)"
fi
fi  # item 6

########################################################################
# Item 7: other targets unchanged
########################################################################
if want 7; then
echo "== item 7: other targets unchanged"
glog=$EVIDENCE_DIR/item7-guards.log
ulog=$EVIDENCE_DIR/item7-unifdef.log
dlog=$EVIDENCE_DIR/item7-diff.log
: >"$ulog"
ok=yes
# every line added since the wave base, with the stack of #if conditions it is in
{
    echo "\$ git -C wine diff $WINE_WAVE_BASE HEAD -- $WAVE_FILES: every added line with its enclosing #if stack"
    for f in $WAVE_FILES; do
        git -C "$WINE_DIR" show "HEAD:$f" >"$WORK/guard.c"
        git -C "$WINE_DIR" diff -U0 "$WINE_WAVE_BASE" HEAD -- "$f" | sed -n 's/^@@ -[0-9,]* +\([0-9]*\),\{0,1\}\([0-9]*\) @@.*/\1 \2/p' >"$WORK/hunks"
        perl -e '
            my ($file, $hunks) = @ARGV; open my $fh, "<", $file or die; my @lines = <$fh>;
            open my $hh, "<", $hunks or die; my %added;
            while (<$hh>) { my ($s, $n) = split; $n = 1 if $n eq ""; $added{$_} = 1 for $s .. $s + $n - 1; }
            my @stack; my $i = 0;
            for my $l (@lines) {
                $i++;
                # The conditions the line is in. The #if, #else and #endif lines themselves and empty
                # lines are not judged here: diff pairs a new #endif or an empty line with an old one
                # as it likes, and the unifdef comparison below is what shows that the conditionals
                # leave the other targets their old text.
                my $directive = 0;
                if ($l =~ /^\s*#\s*(if|ifdef|ifndef)\b(.*)/) { push @stack, "$1$2"; $directive = 1; }
                elsif ($l =~ /^\s*#\s*(elif)\b(.*)/) { $stack[-1] = "$1$2 (after $stack[-1])"; $directive = 1; }
                elsif ($l =~ /^\s*#\s*else\b/) { $stack[-1] = "else of $stack[-1]"; $directive = 1; }
                elsif ($l =~ /^\s*#\s*endif\b/) { pop @stack; $directive = 1; }
                next unless $added{$i};
                next if $directive || $l =~ /^\s*$/;
                my @in = @stack;
                my @g = grep { /^if defined\(__APPLE__\) && defined\(__aarch64__\)\s*$|^ifdef WX_EXCLUSIVE_HOST\s*$/ } @in;
                printf "%s %s:%d [%s] %s", (@g ? "guarded" : "UNGUARDED"), $ARGV[2], $i, join(" > ", map { s/\s+/ /gr } @in), $l;
            }' "$WORK/guard.c" "$WORK/hunks" "$f"
    done
} >"$glog" 2>&1
nadd=$(grep -c -E '^(guarded|UNGUARDED) ' "$glog")
nung=$(grep -c '^UNGUARDED ' "$glog")
[ "$nung" = 0 ] && [ "$nadd" -gt 0 ] || ok=no
echo "--- added lines other than conditionals and empty lines: $nadd, outside a defined(__APPLE__) && defined(__aarch64__) or WX_EXCLUSIVE_HOST guard: $nung" >>"$glog"
# WX_EXCLUSIVE_HOST counts as that guard because it is only ever defined inside it
nwxbad=0
for f in $WAVE_FILES; do
    bad=$(git -C "$WINE_DIR" show "HEAD:$f" | perl -ne '
        if (/^\s*#\s*(if|ifdef|ifndef)\b(.*)/) { push @stack, "$1$2"; }
        elsif (/^\s*#\s*(elif|else)\b/) { $stack[-1] = "other branch of $stack[-1]"; }
        elsif (/^\s*#\s*endif\b/) { pop @stack; }
        elsif (/^\s*#\s*(define|undef)\s+WX_EXCLUSIVE_HOST\b/) {
            $n++ unless grep { /^if defined\(__APPLE__\) && defined\(__aarch64__\)\s*$/ } @stack;
        }
        END { print $n + 0 }')
    [ "$bad" = 0 ] || { nwxbad=$((nwxbad + bad)); echo "$f: WX_EXCLUSIVE_HOST defined or undefined outside the guard, $bad times" >>"$glog"; }
done
[ "$nwxbad" = 0 ] || ok=no
# Source level: for every other system (__APPLE__ undefined) and for x86_64 macOS (__aarch64__
# undefined) each file is the wave base text.
for f in $WAVE_FILES; do
    for flags in "-U__APPLE__ -UWX_EXCLUSIVE_HOST" "-D__APPLE__ -U__aarch64__ -UWX_EXCLUSIVE_HOST"; do
        git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$f" | unifdef $flags | cat -s >"$WORK/unifdef.base" 2>/dev/null
        git -C "$WINE_DIR" show "HEAD:$f" | unifdef $flags | cat -s >"$WORK/unifdef.new" 2>/dev/null
        if [ -s "$WORK/unifdef.new" ] && cmp -s "$WORK/unifdef.base" "$WORK/unifdef.new"; then
            echo "unifdef $flags $f: identical to $WINE_WAVE_BASE" >>"$ulog"
        else
            ok=no; echo "unifdef $flags $f: DIFFERS from $WINE_WAVE_BASE" >>"$ulog"
            diff "$WORK/unifdef.base" "$WORK/unifdef.new" | head -20 >>"$ulog"
        fi
    done
done
{
    echo "\$ git -C wine diff --stat $WINE_WAVE_BASE HEAD"
    git -C "$WINE_DIR" diff --stat "$WINE_WAVE_BASE" HEAD
    echo "\$ git -C wine log --format='%h %s' $WINE_WAVE_BASE..HEAD"
    git -C "$WINE_DIR" log --format='%h %s' "$WINE_WAVE_BASE..HEAD"
    echo "\$ git -C wine status --porcelain"
    git -C "$WINE_DIR" status --porcelain
    echo "\$ git diff --stat $SUPER_WAVE_BASE HEAD   (superproject)"
    git -C "$PROTON_DIR" diff --stat "$SUPER_WAVE_BASE" HEAD
    echo "\$ git diff --raw $SUPER_WAVE_BASE HEAD -- wine   (submodule pointer must be unchanged)"
    git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine
} >"$dlog" 2>&1
wbad=""
for f in $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD); do
    case " $WAVE_FILES " in *" $f "*) ;; *) wbad="$wbad $f" ;; esac
done
wdirty=$(git -C "$WINE_DIR" status --porcelain --untracked-files=all | head -5)
sbad=$(git -C "$PROTON_DIR" diff --name-only "$SUPER_WAVE_BASE" HEAD | grep -v '^macos/' | grep -v -x -F -e lsteamclient/unixlib.cpp -e lsteamclient/unix_steam_input_manual.cpp)
[ -n "$(git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine)" ] && sbad="$sbad wine(pointer)"
[ -z "$wbad" ] && [ -z "$wdirty" ] && [ -z "$sbad" ] || ok=no
if [ $ok = yes ]; then
    pass 7 "$nadd lines added since $WINE_WAVE_BASE in $(echo $WAVE_FILES), all under defined(__APPLE__) && defined(__aarch64__) or WX_EXCLUSIVE_HOST, which is only defined under it; the files are the wave base text with __APPLE__ or __aarch64__ undefined; superproject changes only in macos/ ($glog, $ulog, $dlog)"
else
    fail 7 "unguarded lines: $nung of $nadd; WX_EXCLUSIVE_HOST defined outside the guard: $nwxbad; wine unexpected:${wbad:- none}; wine uncommitted: '$wdirty'; superproject: '$(echo $sbad)' ($glog, $ulog, $dlog)"
fi
fi  # item 7

########################################################################
# Item 8: audio output
########################################################################
if want 8 && needs_unlocked 8; then
echo "== item 8: audio output, x86_64 x $AUDIO_RUNS"
adir=$EVIDENCE_DIR/item8-audio
rm -rf "$adir"; mkdir -p "$adir"
PREFIX=$BUILD_ROOT/wave4-prefix-audio
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
AUDIO_LINE='audio: devices [1-9][0-9]*, first "[^"]+", open 0, write 0, done 1, position [0-9]+/14400'
apass=0; t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
for i in $(seq 1 "$AUDIO_RUNS"); do
    WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/audio_test_x64.exe" >"$adir/run$i.stdout" 2>"$adir/run$i.stderr"
    rc=$?
    t=$RUN_TIMEOUT
    out=$(tr -d '\r' <"$adir/run$i.stdout" | head -1)
    line=no; echo "$out" | grep -Eqx "$AUDIO_LINE" && line=yes
    [ "$rc" = 0 ] && [ $line = yes ] && apass=$((apass + 1))
    echo "run $i: exit=$rc line=$line ($out)" >>"$adir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$apass" = "$AUDIO_RUNS" ]; then
    pass 8 "audio_test_x64.exe played 300 ms of silence to the end on the default output in $apass/$AUDIO_RUNS runs: '$out' ($adir/summary.txt)"
else
    fail 8 "audio_test_x64.exe passed $apass/$AUDIO_RUNS runs: '$out' ($adir/summary.txt)"
fi
fi  # item 8

########################################################################
# Item 9: Direct3D 12 through vkd3d-proton, off screen
########################################################################
if want 9; then
echo "== item 9: Direct3D 12 through vkd3d-proton, off screen, x86_64 x $D3D_RUNS"
kdir=$EVIDENCE_DIR/item9-d3d12
rm -rf "$kdir"; mkdir -p "$kdir"
PREFIX=$BUILD_ROOT/wave4-prefix-d3d12
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hold_server "$PREFIX"
D3D12_LINE='d3d12: vkd3d 1, adapter "[^"]+", feature level [bc][01]00, pixel [0-9a-f]{8}, expected 4080bfff'
kpass=0; t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
for i in $(seq 1 "$D3D_RUNS"); do
    # vkd3d-proton would otherwise leave its shader cache in the working directory
    WINEPREFIX=$PREFIX VKD3D_SHADER_CACHE_PATH=0 run_timeout "$t" "$WINE" "$TESTS_OUT/d3d12_test_x64.exe" >"$kdir/run$i.stdout" 2>"$kdir/run$i.stderr"
    rc=$?
    t=$RUN_TIMEOUT
    out=$(tr -d '\r' <"$kdir/run$i.stdout" | head -1)
    line=no; echo "$out" | grep -Eqx "$D3D12_LINE" && line=yes
    [ "$rc" = 0 ] && [ $line = yes ] && kpass=$((kpass + 1))
    echo "run $i: exit=$rc line=$line ($out)" >>"$kdir/summary.txt"
done
cleanup_prefix "$PREFIX"
{
    echo "vkd3d-proton said: $(grep -a -h -o 'vkd3d-proton - build: [0-9a-f]*' "$kdir"/run1.stderr | head -1)"
    echo "vkd3d-proton in the install tree:"
    ls -l "$INSTALL_DIR/lib/wine/aarch64-windows/d3d12.dll" "$INSTALL_DIR/lib/wine/aarch64-windows/d3d12core.dll" 2>&1
} >>"$kdir/summary.txt"
if [ "$kpass" = "$D3D_RUNS" ]; then
    pass 9 "d3d12_test_x64.exe drew into a texture with vkd3d-proton and read its colour back in $kpass/$D3D_RUNS runs: '$out' ($kdir/summary.txt)"
else
    fail 9 "d3d12_test_x64.exe passed $kpass/$D3D_RUNS runs: '$out' ($kdir/summary.txt)"
fi
fi  # item 9

########################################################################
# Item 10: Direct3D 12 in a window
########################################################################
if want 10 && needs_unlocked 10; then
echo "== item 10: Direct3D 12 swap chain in a window, x86_64, $D3D_FRAMES frames"
wdir=$EVIDENCE_DIR/item10-d3d12-window
rm -rf "$wdir"; mkdir -p "$wdir"
PREFIX=$BUILD_ROOT/wave4-prefix-d3d12-window
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
# set the prefix up first and wait for that session to end, so that the timed run is alone
WINEPREFIX=$PREFIX VKD3D_SHADER_CACHE_PATH=0 run_timeout "$WINEBOOT_TIMEOUT" "$WINE" "$TESTS_OUT/d3d12_window_test_x64.exe" 2 >"$wdir/setup.stdout" 2>"$wdir/setup.stderr"
echo "prefix setup: exit=$? $(tr -d '\r' <"$wdir/setup.stdout")" >>"$wdir/summary.txt"
WINEPREFIX=$PREFIX run_timeout 60 "$SERVER" -w >/dev/null 2>&1
SWAP12_LINE="d3d12 window: vkd3d 1, swap chain 0, 640x360, presented $D3D_FRAMES/$D3D_FRAMES, back buffer [0-9a-f]{6}"
D3D12_WINDOW=$(printf '\t640x360\t200,200\t[0-9-]+\t%s\t[01]$' "$BUNDLE_LOADER")
WINEPREFIX=$PREFIX VKD3D_SHADER_CACHE_PATH=0 run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/d3d12_window_test_x64.exe" "$D3D_FRAMES" >"$wdir/run.stdout" 2>"$wdir/run.stderr" &
spid=$!
# the frames take a few seconds at the display's rate; ask the window server while they run
nopen=0
for i in $(seq 1 80); do
    nap 0.25
    nopen=$("$TESTS_OUT/list_windows" "$INSTALL_DIR" 2>/dev/null | tee "$wdir/mac-open.txt" | grep -c -E "$D3D12_WINDOW")
    [ "$nopen" -ge 1 ] && break
    kill -0 $spid 2>/dev/null || break
done
wait $spid
rc=$?
WINEPREFIX=$PREFIX run_timeout 60 "$SERVER" -w >/dev/null 2>&1
out=$(tr -d '\r' <"$wdir/run.stdout" | head -1)
line=no; echo "$out" | grep -Eqx "$SWAP12_LINE" && line=yes
nswap=$(grep -a -c 'vkd3d-proton:dxgi_vk_swap_chain_init: Creating swapchain (640 x 360)' "$wdir/run.stderr")
echo "run: exit=$rc line=$line ($out); the window server had the window while it ran: $nopen; vkd3d-proton's 'Creating swapchain (640 x 360)': $nswap" >>"$wdir/summary.txt"
cleanup_prefix "$PREFIX"
if [ "$rc" = 0 ] && [ $line = yes ] && [ "$nopen" -ge 1 ] && [ "$nswap" -ge 1 ]; then
    pass 10 "d3d12_window_test_x64.exe got a swap chain on its window from vkd3d-proton and presented every frame: '$out' ($wdir/summary.txt)"
else
    fail 10 "exit $rc, line $line: '$out'; window listed $nopen; vkd3d-proton created a swap chain $nswap times ($wdir/summary.txt)"
fi
fi  # item 10

########################################################################
# Item 11: a real program, the Godot editor
########################################################################
if want 11; then
echo "== item 11: the Godot editor's project manager, $GODOT_FRAMES frames: arm64 on Vulkan and Direct3D 12, x86_64 on Vulkan"
gdir=$EVIDENCE_DIR/item11-godot
rm -rf "$gdir"; mkdir -p "$gdir"
GODOT_ARM64=$(ls "$GODOT_DIR"/arm64/Godot_v*_windows_arm64.exe 2>/dev/null | head -1)
GODOT_X64=$(ls "$GODOT_DIR"/x86_64/Godot_v*_win64.exe 2>/dev/null | head -1)
if [ -z "$GODOT_ARM64" ] || [ -z "$GODOT_X64" ]; then
    todo "item 11: the Godot editor is not in $GODOT_DIR (macos/tests/fetch-godot.sh downloads it); no real program was run"
else
    PREFIX=$BUILD_ROOT/wave4-prefix-godot
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    hold_server "$PREFIX"
    # godot_run NAME EXE DRIVER TIMEOUT: sets grc and gline, the line that names the renderer and device
    godot_run() {
        WINEPREFIX=$PREFIX VKD3D_SHADER_CACHE_PATH=0 run_timeout "$4" "$WINE" "$2" --project-manager --rendering-driver "$3" --quit-after "$GODOT_FRAMES" >"$gdir/$1.stdout" 2>"$gdir/$1.stderr"
        grc=$?
        gline=$(tr -d '\r' <"$gdir/$1.stdout" | grep -a -m1 -E '^(Vulkan [0-9.]+|D3D12 [0-9_]+) - .* - Using Device #0: .+')
        echo "$1: exit=$grc (142 = stopped after $4 s) '$gline'; last line: '$(tr -d '\r' <"$gdir/$1.stdout" | grep -a -v '^$' | tail -1 | cut -c1-100)'" >>"$gdir/summary.txt"
    }
    gpass=0
    godot_run arm64-vulkan "$GODOT_ARM64" vulkan "$WINEBOOT_TIMEOUT"   # the first run sets the prefix up
    [ "$grc" = 0 ] && echo "$gline" | grep -q '^Vulkan ' && gpass=$((gpass + 1)); vline=$gline
    godot_run arm64-d3d12 "$GODOT_ARM64" d3d12 "$RUN_TIMEOUT"
    [ "$grc" = 0 ] && echo "$gline" | grep -q '^D3D12 ' && gpass=$((gpass + 1)); dline=$gline
    godot_run x86_64-vulkan "$GODOT_X64" vulkan "$GODOT_X64_TIMEOUT"
    xok=no; [ "$grc" = 0 ] && echo "$gline" | grep -q '^Vulkan ' && xok=yes
    cleanup_prefix "$PREFIX"
    if [ "$gpass" = 2 ] && [ $xok = yes ]; then
        pass 11 "the Godot editor ran $GODOT_FRAMES frames and exited 0: arm64 '$vline' and '$dline', x86_64 '$gline' ($gdir/summary.txt)"
    elif [ "$gpass" = 2 ] && [ -z "$LOADER_PROFILE" ]; then
        pass 11 "the arm64 Godot editor ran $GODOT_FRAMES frames and exited 0 on both renderers: '$vline' and '$dline' ($gdir/summary.txt)"
        todo "item 11: the x86_64 Godot editor does not get through $GODOT_FRAMES frames (exit $grc, 142 = stopped after $GODOT_X64_TIMEOUT s; it got to '$gline'). One cause is known: FEX's guard pages need 4K pages, which need LOADER_PROFILE (check-wave3b.sh item 9) ($gdir/summary.txt)"
    else
        fail 11 "the Godot editor: arm64 passed $gpass of 2 renderers ('$vline', '$dline'); x86_64 on Vulkan ok=$xok (exit $grc, '$gline') ($gdir/summary.txt)"
    fi
fi
fi  # item 11

todo "that Direct3D 11 frames are on the screen, that a window's picture follows a resize, and a game have no items yet; Wave 4 is not done"

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
[ $FAILED = 0 ] || exit 1
[ $TODO = 0 ] || exit 3
exit 0
