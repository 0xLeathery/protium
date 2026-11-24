#!/bin/bash
#
# Measures how evenly a game that turns its camera with the mouse gets the mouse's movement.
#
#   macos/tests/check-mouse.sh [recentre|rawinput|menu|hidden ...]      (default: all four)
#
# For each mode it starts mouse_look_test.exe (a window over the screen that reads the mouse as
# such a game does, see mouse_look_test.c) in the checks' prefix and has mouse_feed move the
# mouse at a fixed speed: COUNTS per event (default 3), 1000 events a second, two seconds to the
# right and two back. Every 60th of a second should then bring the same movement. It prints, per
# mode, PASS or FAIL with the numbers, and for recentre and rawinput the movement of each frame.
#   recentre, rawinput   no frame without movement while the mouse moved, every frame within
#                        SPREAD (default 15) per cent of the middle one, and as many counts
#                        received as sent, within 2 per cent
#   menu                 the pointer is where the program put it when it shows again, and each
#                        click is where the pointer is
#   hidden               with the pointer hidden and left alone (a menu whose pointer the game
#                        draws), it moves by as many pixels as the mouse moved counts, and a
#                        click is where the pointer is
# IT TAKES THE POINTER AND THE FRONT OF THE SCREEN for about ten seconds per mode: run it only
# when nobody is using the Mac. WINE_MOUSE_TRACE and the other WINE_MOUSE_ variables pass through.
# Logs go to $BUILD_ROOT/evidence/mouse. Exit status: 1 when a mode failed.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
E=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/mouse}
PREFIX=${PREFIX:-$BUILD_ROOT/evidence/wave5/prefix}
COUNTS=${COUNTS:-3}
SPREAD=${SPREAD:-15}
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
WINE=$INSTALL_DIR/bin/wine
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=} WINEDEBUG=${WINEDEBUG:--all} WINEPREFIX=$PREFIX
mkdir -p "$E"
[ -x "$WINE" ] || { echo "check-mouse.sh: no wine at $WINE" >&2; exit 2; }
pgrep -f 'steamplay-run|steam\.exe' >/dev/null && { echo "check-mouse.sh: a game is running; not now" >&2; exit 2; }
"$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang" -O2 -Wall -o "$E/mouse_look_test.exe" "$SCRIPT_DIR/mouse_look_test.c" -luser32 -lgdi32 || exit 2
[ "$E/mouse_feed" -nt "$SCRIPT_DIR/mouse_feed.swift" ] || swiftc -O -o "$E/mouse_feed" "$SCRIPT_DIR/mouse_feed.swift" || exit 2

wait_line() {   # wait_line FILE WORD SECONDS
    local i=0
    while [ $i -lt $(($3 * 10)) ]; do
        grep -q "^$2 " "$1" 2>/dev/null && return 0
        perl -e 'select(undef, undef, undef, 0.1)'
        i=$((i + 1))
    done
    return 1
}

status=0
for mode in ${*:-recentre rawinput menu hidden}; do
    out=$E/$mode.out
    rm -f "$out"
    "$WINE" "$E/mouse_look_test.exe" "$mode" $([ "$mode" = menu ] && echo 4 || { [ "$mode" = hidden ] && echo 5 || echo 9; }) >"$out" 2>"$E/$mode.err" &
    pid=$!
    if [ "$mode" = menu ]; then
        if wait_line "$out" shown 40; then
            set -- $(tr -d '\r' <"$out" | sed -n 's/^shown [-0-9]* [-0-9]* last set //p')
            "$E/mouse_feed" clicks "$1,$2" "400,400" >"$E/$mode.feed" 2>&1
        fi
    elif [ "$mode" = hidden ]; then
        if wait_line "$out" start 40; then
            perl -e 'select(undef, undef, undef, 0.5)'
            "$E/mouse_feed" nudgeclick 100 3 150 -4 >"$E/$mode.feed" 2>&1
        fi
    elif wait_line "$out" start 40; then
        perl -e 'select(undef, undef, undef, 0.4)'
        "$E/mouse_feed" look "$COUNTS" 2 >"$E/$mode.feed" 2>&1
    fi
    wait $pid
    python3 -I - "$mode" "$out" "$E/$mode.feed" "$COUNTS" "$SPREAD" <<'PY' || status=1
import re, sys
mode, out, feed, counts, spread = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), float(sys.argv[5])
lines = open(out, errors="replace").read().split("\n")
sent = open(feed, errors="replace").read()
if mode == "hidden":
    bad = []
    centre = next((re.match(r"screen \d+ \d+ centre (-?\d+) (-?\d+)", l) for l in lines if l.startswith("screen")), None)
    clicks = [re.match(r"click (-?\d+) (-?\d+) pointer (-?\d+) (-?\d+)", l) for l in lines if l.startswith("click")]
    nudges = [int(x) for x in re.findall(r"nudged (-?\d+) clicked", sent)]
    if not nudges or len(clicks) != len(nudges): bad.append("%d clicks seen of %d made" % (len(clicks), len(nudges)))
    x = int(centre[1]) if centre else 0
    for c, n in zip(clicks, nudges):
        x += n
        if abs(int(c[1]) - int(c[3])) > 2 or abs(int(c[2]) - int(c[4])) > 2: bad.append("click at %s,%s with the pointer at %s,%s" % c.groups())
        if abs(int(c[3]) - x) > 3: bad.append("pointer at %s after moving to %d" % (c[3], x))
    print("%s  hidden: %s" % ("FAIL" if bad else "PASS", "; ".join(bad) if bad else "%d clicks where the pointer is, which moved a pixel per count" % len(clicks)))
    sys.exit(1 if bad else 0)
if mode == "menu":
    bad = []
    m = next((re.match(r"shown (-?\d+) (-?\d+) last set (-?\d+) (-?\d+)", l) for l in lines if l.startswith("shown")), None)
    if not m: bad.append("the pointer never showed")
    elif abs(int(m[1]) - int(m[3])) > 2 or abs(int(m[2]) - int(m[4])) > 2: bad.append("shown at %s,%s, put at %s,%s" % m.groups())
    clicks = [re.match(r"click (-?\d+) (-?\d+) pointer (-?\d+) (-?\d+)", l) for l in lines if l.startswith("click")]
    want = re.findall(r"clicked (\d+) (\d+)", sent)
    if not want: bad.append("no clicks were made: %s" % sent.strip()[:80])
    if len(clicks) != len(want): bad.append("%d clicks seen of %d made" % (len(clicks), len(want)))
    for c, w in zip(clicks, want):
        if abs(int(c[1]) - int(c[3])) > 2 or abs(int(c[2]) - int(c[4])) > 2: bad.append("click at %s,%s with the pointer at %s,%s" % c.groups())
        if abs(int(c[1]) - int(w[0])) > 3 or abs(int(c[2]) - int(w[1])) > 3: bad.append("click made at %s,%s seen at %s,%s" % (w[0], w[1], c[1], c[2]))
    print("%s  menu: %s" % ("FAIL" if bad else "PASS", "; ".join(bad) if bad else "pointer shown where it was put, %d clicks where the pointer is" % len(clicks)))
    sys.exit(1 if bad else 0)
frames = [tuple(float(x) for x in l.split()[1:]) for l in lines if l.startswith("frame ")]
dx = [int(f[2]) for f in frames]
m = re.search(r"sent (\d+) (\d+) in (\d+) events", sent)
if not frames or not m:
    print("FAIL  %s: no frames or nothing sent (%s)" % (mode, sent.strip()[:80])); sys.exit(1)
bad, report = [], []
for name, sign, total in (("right", 1, int(m[1])), ("left", -1, int(m[2]))):
    idx = [i for i, d in enumerate(dx) if d * sign > 0]
    if len(idx) < 20:
        bad.append("%s: only %d frames moved" % (name, len(idx))); continue
    leg = [dx[i] * sign for i in range(idx[0], idx[-1] + 1)]
    inner = leg[2:-2]                       # the first and last frames hold part of a frame's worth
    mid = sorted(inner)[len(inner) // 2]
    empty = sum(1 for d in inner if d <= 0)
    off = sum(1 for d in inner if abs(d - mid) > max(1, mid * spread / 100))
    got = sum(leg)
    report.append("%s: %d frames, middle %d, least %d, most %d, %d empty, %d off by more than %g%%, %d of %d counts"
                  % (name, len(inner), mid, min(inner), max(inner), empty, off, spread, got, total))
    if empty: bad.append("%s: %d frames without movement" % (name, empty))
    if off: bad.append("%s: %d frames uneven" % (name, off))
    if abs(got - total) > total * 0.02: bad.append("%s: got %d of %d counts" % (name, got, total))
gets = sorted(f[4] for f in frames); sets = sorted(f[5] for f in frames)
print("%s  %s: %s" % ("FAIL" if bad else "PASS", mode, "; ".join(bad) if bad else "even"))
for r in report: print("      " + r)
print("      GetCursorPos %d us, SetCursorPos %d us (middle values; most %d and %d)" % (gets[len(gets)//2], sets[len(sets)//2], gets[-1], sets[-1]))
first = next((i for i, d in enumerate(dx) if d), 0)
print("      frames from the first that moved: " + " ".join(str(d) for d in dx[first:first + 60]))
sys.exit(1 if bad else 0)
PY
done
exit $status
