#!/bin/bash
#
# How a Vulkan game's frames are paced on this build, measured on the screen, and what swapchains
# made anew leave behind:
#
#   macos/tests/check-vsync.sh [driver dist folder ...]
#
# Runs macos/tests/vk_pacing_test.c (a window of its own, no game) with the install's KosmicKrisp
# and with each other driver named (a dist folder of macos/build-mesa.sh, as
# $BUILD_ROOT/mesa-dist-3drawables), with the driver's own present line on (KK_PRESENT_STATS):
#
#   1. the GPU's time for a frame of each load, unpaced (each frame waited for);
#   2. each load without V-Sync (IMMEDIATE), with 10 ms of processor work a frame: what the frame
#      rate can be;
#   3. each load with V-Sync (FIFO) and the 2 images DOOM (2016) asks for, then with the 3 the
#      surface says it wants: frame rate, frame times, the wait in vkAcquireNextImageKHR;
#   4. 100 swapchains made anew on a shown window, each presenting a frame, then each acquiring
#      an image and dropping it, and the same on a minimized window: the IOSurface memory of the
#      process before and after (vmmap).
#
# One verdict for each driver and question:
#   pacing  PASS when V-Sync with 2 images reaches, at every load, at least 80% of the rate
#           without V-Sync (which the screen's refresh rate caps);
#   memory  PASS when no run of 100 swapchains leaves more than 8 images' worth of IOSurface.
#
# It takes the screen for about five minutes (a window over all of it) and needs the screen
# unlocked and nothing else drawing: a hidden window's frames are not shown, and are paced another
# way. Do not run it while a game is running; it refuses when a wineserver is up. Results are
# kept in $EVIDENCE_DIR, one folder for each run.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
MESA_SRC=${MESA_SRC:-$BUILD_ROOT/mesa-src}
PREFIX=${PREFIX:-$BUILD_ROOT/evidence/wave5/prefix}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/vsync}
LOADS=${LOADS:-24,48,72,96}
STEP_SECONDS=${STEP_SECONDS:-6}
SWAPCHAINS=${SWAPCHAINS:-100}
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
WINE=$INSTALL_DIR/bin/wine

[ -x "$WINE" ] || { echo "check-vsync: no Wine at '$WINE' (BUILD_DIR=$BUILD_DIR)" >&2; exit 2; }
[ -d "$PREFIX" ] || { echo "check-vsync: no prefix at $PREFIX; run check-wave5.sh once" >&2; exit 2; }
[ -f "$MESA_SRC/include/vulkan/vulkan.h" ] || { echo "check-vsync: no Vulkan headers in $MESA_SRC/include (run macos/build-mesa.sh)" >&2; exit 2; }
if pgrep -x wineserver >/dev/null; then
    echo "check-vsync: a wineserver is running (a game?); the numbers would not be this test's" >&2
    exit 2
fi
if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes' && [ -z "${VSYNC_LOCKED_OK:-}" ]; then
    echo "check-vsync: the screen is locked: nothing a window draws is shown then, and the frames are paced" >&2
    echo "another way. Unlock the screen and run it again (VSYNC_LOCKED_OK=1 runs it all the same)." >&2
    exit 2
fi

out=$EVIDENCE_DIR/check-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
exe=$out/vk_pacing_test.exe
"$TOOLCHAIN_DIR/bin/x86_64-w64-mingw32-clang" -O2 -Wall -I"$MESA_SRC/include" -o "$exe" "$SCRIPT_DIR/vk_pacing_test.c" -luser32 \
    >"$out/build.log" 2>&1 || { echo "check-vsync: vk_pacing_test.c did not build, see $out/build.log" >&2; exit 2; }

# the screen stays on while this runs
/usr/bin/caffeinate -d -u -t 600 &
caffeinate_pid=$!
trap 'kill $caffeinate_pid 2>/dev/null' EXIT

# run NAME LIMIT ICD ARGS...: the test with a time limit, its output in $out/NAME.log. A run that
# ended without a word of the test's (the first start after the screen woke was once killed) is
# made once more.
run() {
    local name=$1 limit=$2 icd=$3 try
    shift 3
    for try in 1 2; do
        (
            export WINEPREFIX="$PREFIX" WINEFSYNC=1 WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" KK_PRESENT_STATS=$STEP_SECONDS
            [ -z "$icd" ] || export VK_DRIVER_FILES="$icd"
            exec /usr/bin/perl -e 'alarm shift; exec @ARGV' "$limit" "$WINE" "$exe" "$@"
        ) >"$out/$name.log" 2>&1
        ! grep -a -q '^vk pacing test:' "$out/$name.log" || break
        cp "$out/$name.log" "$out/$name.try1.log"
    done
}

# leak NAME ICD ARGS...: "recreate" with the process's IOSurface memory at each MARK line
leak() {
    local name=$1 icd=$2 seen=0 marks mark pid
    shift 2
    run "$name" 240 "$icd" "$@" recreate="$SWAPCHAINS" hold=5 &
    local job=$!
    while kill -0 $job 2>/dev/null; do
        marks=$(grep -a -c '^MARK ' "$out/$name.log" 2>/dev/null)
        if [ "${marks:-0}" -gt "$seen" ]; then
            seen=$marks
            mark=$(grep -a '^MARK ' "$out/$name.log" | tail -1 | cut -d' ' -f2 | tr -d '\r')
            pid=$(pgrep -f 'vk_pacing_test.exe' | while read -r p; do echo "$(ps -o rss= -p "$p") $p"; done | sort -rn | head -1 | awk '{print $2}')
            [ -z "$pid" ] || vmmap --summary "$pid" >"$out/$name.$mark.vmmap" 2>/dev/null
        fi
        /bin/sleep 0.3
    done
}

drivers=("install=")
for dist in "$@"; do
    icd=$dist/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json
    [ -f "$icd" ] || { echo "check-vsync: no driver manifest $icd" >&2; exit 2; }
    drivers+=("$(basename "$dist")=$icd")
done

for driver in "${drivers[@]}"; do
    name=${driver%%=*} icd=${driver#*=}
    echo ":: $name: GPU time, then without V-Sync, then V-Sync with 2 and with 3 images" >&2
    run "$name.gpu" 120 "$icd" mode=immediate serial=1 size=screen secs=3 loads="$LOADS"
    run "$name.immediate" 180 "$icd" mode=immediate images=2 cpu=10 size=screen secs="$STEP_SECONDS" loads="$LOADS"
    run "$name.fifo2" 180 "$icd" mode=fifo images=2 cpu=10 size=screen secs="$STEP_SECONDS" loads="$LOADS"
    run "$name.fifo3" 180 "$icd" mode=fifo images=3 cpu=10 size=screen secs="$STEP_SECONDS" loads="$LOADS"
    echo ":: $name: $SWAPCHAINS swapchains made anew, four ways" >&2
    leak "$name.leak-present" "$icd" mode=fifo images=2 size=screen frames=1
    leak "$name.leak-drop" "$icd" mode=fifo images=2 size=screen drop=1
    leak "$name.leak-minimized" "$icd" mode=fifo images=2 size=screen show=2 frames=1
    leak "$name.leak-minimized-drop" "$icd" mode=fifo images=2 size=screen show=2 drop=1
done

/usr/bin/python3 -I - "$out" "${drivers[@]}" <<'EOF' | tee "$out/summary.txt"
import os, re, sys
out, drivers = sys.argv[1], [d.split("=")[0] for d in sys.argv[2:]]
STEP = re.compile(r"^step load (\d+): (\d+) frames in ([\d.]+) s \(([\d.]+) fps\), frame ms median ([\d.]+), 95% ([\d.]+), worst ([\d.]+); "
                  r"acquire ([\d.]+) ms, present ([\d.]+) ms; gpu ([\d.]+) ms a frame, submit to done ([\d.]+) ms; suboptimal (\d+), "
                  r"out of date (\d+), not ready (\d+); frame times:(.*)$", re.M)

def read(name):
    try:
        with open(os.path.join(out, name), errors="replace") as f:
            return f.read()
    except OSError:
        return ""

def steps(name):
    return {int(m[1]): m for m in STEP.finditer(read(name + ".log"))}

def mb(text):
    return float(text[:-1]) * {"K": 1 / 1024, "M": 1, "G": 1024}[text[-1]] if text and text[-1] in "KMG" else 0.0

def surfaces(name, mark):
    m = re.search(r"^IOSurface\s+(\S+)", read("%s.%s.vmmap" % (name, mark)), re.M)
    return mb(m[1]) if m else 0.0

failed = False
for d in drivers:
    gpu, free, two, three = (steps("%s.%s" % (d, k)) for k in ("gpu", "immediate", "fifo2", "fifo3"))
    print("\n== %s\n%5s %9s %12s %30s %30s" % (d, "load", "GPU ms", "no V-Sync", "V-Sync, 2 images", "V-Sync, 3 images"))
    ok = bool(free and two)
    for load in sorted(free):
        def cell(s):
            m = s.get(load)
            return "%5.1f fps, acquire %4.1f ms" % (float(m[4]), float(m[8])) if m else "no run"
        print("%5d %9s %8s fps %30s %30s" % (load, gpu[load][10] if load in gpu else "?", free[load][4], cell(two), cell(three)))
        if load not in two or float(two[load][4]) < 0.8 * float(free[load][4]):
            ok = False
    for load in sorted(two):
        print("      V-Sync, 2 images, load %d, frame times:%s" % (load, two[load][15]))
    lines = [l for l in read(d + ".fifo2.log").splitlines() if "KosmicKrisp: presents" in l]
    if lines:
        print("      the driver's last line: " + lines[-1].split("): ", 1)[-1][:700])
    print("pacing %s: %s" % ("PASS" if ok else "FAIL", d))
    failed = failed or not ok
    image_mb = 0.0
    m = re.search(r"swapchain: \d+ images of (\d+)x(\d+)", read(d + ".leak-present.log"))
    if m:
        image_mb = int(m[1]) * int(m[2]) * 4 / (1 << 20)
    ok = image_mb > 0
    for kind in ("leak-present", "leak-drop", "leak-minimized", "leak-minimized-drop"):
        name = "%s.%s" % (d, kind)
        before, after = surfaces(name, "before"), surfaces(name, "after")
        made = re.search(r"recreate: (\d+) swapchains made", read(name + ".log"))
        print("%-22s IOSurface %7.1f MB before, %7.1f MB after %s swapchains (an image is %.1f MB)"
              % (kind, before, after, made[1] if made else "no", image_mb))
        if not made or after - before > 8 * image_mb:
            ok = False
    print("memory %s: %s" % ("PASS" if ok else "FAIL", d))
    failed = failed or not ok
print("\nkept in " + out)
sys.exit(1 if failed else 0)
EOF
