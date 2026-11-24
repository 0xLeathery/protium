#!/bin/bash
#
# Checks what programs are told of the display, in points and in pixels (Wine's Retina mode).
#
#   macos/tests/check-hires.sh
#
# It runs display_report.exe (a console program, no window) under three settings of
# WINE_MAC_RETINA and compares what it prints:
#   off     0: the display in points, whatever it is
#   on      1: Retina mode whatever the display: twice the points each way
#   auto    unset: pixels when the main display has two pixels to a point, else points; on a
#           display of one pixel to a point this is the case that keeps every game as it was
# and in each of them the monitor's rectangle, the current mode, SM_CXSCREEN and
# GetDeviceCaps(HORZRES) have to be the same size, and the mode list has to reach it. Then, with
# Retina mode on, the tests that hand a frame over (Direct3D 9, 11, 12 and OpenGL) have to pass
# as they do without; those open a small window for a moment.
# Prints PASS or FAIL per case; exit status 1 when one failed.
#
# Environment overrides: BUILD_ROOT, INSTALL_DIR (default $BUILD_ROOT/install-aarch64), PREFIX
# (default $BUILD_ROOT/evidence/wave5/prefix), TOOLCHAIN_DIR, EVIDENCE_DIR (default
# $BUILD_ROOT/evidence/hires/check).

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
INSTALL_DIR=${INSTALL_DIR:-$BUILD_ROOT/install-aarch64}
PREFIX=${PREFIX:-$BUILD_ROOT/evidence/wave5/prefix}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
E=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/hires/check}
WINE=$INSTALL_DIR/bin/wine
SERVER=$INSTALL_DIR/bin/wineserver
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=} WINEDEBUG=${WINEDEBUG:--all} WINEPREFIX=$PREFIX
mkdir -p "$E"
[ -x "$WINE" ] || { echo "check-hires.sh: no wine at $WINE" >&2; exit 2; }
pgrep -f 'steamplay-run|steam\.exe' >/dev/null && { echo "check-hires.sh: a game is running; not now" >&2; exit 2; }

FAILED=0
pass() { echo "PASS  $1: $2"; }
fail() { echo "FAIL  $1: $2"; FAILED=1; }
cc() { "$TOOLCHAIN_DIR/bin/$1-w64-mingw32-clang" -O2 -Wall -o "$E/$2" "$SCRIPT_DIR/$3" "${@:4}" >>"$E/build.log" 2>&1 || { echo "check-hires.sh: $3 did not build ($E/build.log)" >&2; exit 2; }; }
: >"$E/build.log"
cc aarch64 display_report.exe display_report.c -luser32 -lgdi32
cc x86_64 d3d9_test.exe d3d9_test.c -ld3d9 -luser32
cc x86_64 d3d11_window_test.exe d3d11_window_test.c -ld3d11 -ldxguid -luuid -luser32
cc x86_64 d3d12_window_test.exe d3d12_window_test.c -ld3d12 -ldxgi -ldxguid -luuid -luser32
cc x86_64 opengl_test.exe opengl_test.c -lopengl32 -lgdi32 -luser32
# whether the main display has two pixels to a point
cat >"$E/hidpi.swift" <<'SWIFT'
import CoreGraphics
let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())!
print(mode.pixelWidth == 2 * mode.width ? "yes" : "no")
SWIFT
[ "$E/hidpi" -nt "$0" ] || swiftc -O -o "$E/hidpi" "$E/hidpi.swift" 2>>"$E/build.log" || exit 2
hidpi=$("$E/hidpi")

# run NAME SECONDS [VAR=value] -- program args: its output in $E/NAME.out
run() {
    local name=$1 seconds=$2 setting=$3
    shift 4
    "$SERVER" -k >/dev/null 2>&1
    sleep 1
    ( env $setting "$WINE" "$@" >"$E/$name.out" 2>"$E/$name.err" </dev/null &
      pid=$!; ( sleep "$seconds"; kill $pid 2>/dev/null ) & wait $pid ) 2>/dev/null
}
field() { tr -d '\r' <"$E/$1.out" | sed -n "s/^$2 //p" | head -1; }

for mode in off on auto; do
    case $mode in off) setting=WINE_MAC_RETINA=0 ;; on) setting=WINE_MAC_RETINA=1 ;; auto) setting=WINE_MAC_RETINA=auto ;; esac
    run "report-$mode" 60 "$setting" -- "$E/display_report.exe"
    monitor=$(field "report-$mode" monitor)
    current=$(field "report-$mode" current); current=${current%@*}
    if [ -n "$monitor" ] && [ "$monitor" = "$current" ] && [ "$monitor" = "$(field "report-$mode" metrics)" ] \
            && [ "$monitor" = "$(field "report-$mode" devcaps)" ] && [ "$monitor" = "$(field "report-$mode" largest)" ]; then
        pass "$mode-agrees" "monitor, mode, largest mode, metrics and device size are all $monitor"
    else
        fail "$mode-agrees" "$(tr -d '\r' <"$E/report-$mode.out" | tr '\n' ';')"
    fi
done
off=$(field report-off monitor); on=$(field report-on monitor); auto=$(field report-auto monitor)
[ -n "$off" ] && [ "$on" = "$((${off%x*} * 2))x$((${off#*x} * 2))" ] && pass on-doubles "$off in points, $on in Retina mode" \
    || fail on-doubles "$off in points, $on in Retina mode"
if [ "$hidpi" = yes ]; then want=$on; else want=$off; fi
[ -n "$auto" ] && [ "$auto" = "$want" ] && pass auto "$auto on a display that has $([ "$hidpi" = yes ] && echo two pixels || echo one pixel) to a point" \
    || fail auto "$auto, where $want is right for this display"

for t in d3d9_test:"pixel 3366cc" d3d11_window_test:"presented 60/60" d3d12_window_test:"presented 60/60" opengl_test:"pixel 3366cc"; do
    name=${t%%:*}
    run "retina-$name" 90 WINE_MAC_RETINA=1 -- "$E/$name.exe"
    line=$(tr -d '\r' <"$E/retina-$name.out" | tail -1)
    echo "$line" | grep -q "${t#*:}" && pass "retina-$name" "$line" || fail "retina-$name" "${line:-nothing printed}"
done
"$SERVER" -k >/dev/null 2>&1
exit $FAILED
