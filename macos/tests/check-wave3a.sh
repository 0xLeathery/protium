#!/bin/bash
#
# Wave 3a acceptance check for the native arm64 macOS Wine build: the TEB is in x18 again, kept by
# Apple's custom x18 ABI (an ad-hoc signed loader with com.apple.security.custom-x18-abi-toggle;
# every Wine thread opts in), and memory that is writable and executable in Windows terms works
# by flipping host pages between writable and executable.
#
#   macos/tests/check-wave3a.sh                  # incremental build, then every item
#   FULL_BUILD=yes macos/tests/check-wave3a.sh   # wipe $BUILD_DIR first (full build)
#
# Items (pass/fail):
#   1  the loader (loader/wine and the wine launcher) carries exactly the x18 entitlement and its
#      signature verifies; wineserver is left alone (log name says full or incremental build)
#   2  no TSD-slot TEB loads (mrs TPIDRRO_EL0; ldr [..,#0x30]) left in the aarch64-windows PE
#      modules; NtCurrentTeb() in ntdll.dll reads x18
#   3  wine hello.exe prints its line and exits 0, HELLO_RUNS runs (the first in a fresh prefix)
#   4  wine teb_test.exe (x18 version) passes, TEB_TEST_RUNS runs
#   5  negative control: the loader (loader/wine and the launcher, which loads ntdll.so itself)
#      re-signed without the entitlement stops with the error that names the entitlement and runs
#      no PE code; both are signed with the entitlement again after
#   6  wine wx_test.exe passes, parts a-k (PAGE_EXECUTE_READWRITE, mixed host page, 8 threads, exec
#      heap, stores into their own page, hot patching, server replies and WriteProcessMemory into
#      executed pages, concurrent displaced stores, a refused store-exclusive)
#   7  wineboot -u in a fresh prefix, WINEBOOT_RUNS runs: exit 0, winedevice.exe never faults
#   8  regression: check-wave1.sh, check-wave2a.sh and check-wave2b.sh pass
#   9  other targets unchanged: every change of this wave is under __APPLE__ (unifdef), Unix
#      objects for x86_64 macOS and PE objects identical to the wave base; diff scope
# The build (macos/build-wine.sh) and the test programs are built first ("build").
# Logs go to $EVIDENCE_DIR.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
WINE_DIR=$PROTON_DIR/wine
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
SRC_DIR=${SRC_DIR:-$BUILD_ROOT/wine-src}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave3a}
ENTITLEMENTS=${ENTITLEMENTS:-$PROTON_DIR/macos/wine-loader.entitlements}
# wine commit this wave starts from (tip of macos-arm64 after Wave 2b) and the wine upstream base
WINE_WAVE_BASE=${WINE_WAVE_BASE:-12ebeaa9e1021a11b0b271b5ded4d01c36d744b5}
WINE_BASE=${WINE_BASE:-e60892cc2398b0a83c332a2078c7b85e47bdb42b}
SUPER_WAVE_BASE=${SUPER_WAVE_BASE:-b5a60b4cbcf7f7ec652ebf638cfece10b7c9d373}
FULL_BUILD=${FULL_BUILD:-no}
WINEBOOT_TIMEOUT=${WINEBOOT_TIMEOUT:-300}
RUN_TIMEOUT=${RUN_TIMEOUT:-120}
HELLO_RUNS=${HELLO_RUNS:-5}
TEB_TEST_RUNS=${TEB_TEST_RUNS:-20}
WX_RUNS=${WX_RUNS:-3}
WINEBOOT_RUNS=${WINEBOOT_RUNS:-25}
X18_ENTITLEMENT=com.apple.security.custom-x18-abi-toggle
# Wine files this wave may change: the reverted Wave 2b TSD slot files, and the x18 opt-in and
# W^X page flipping; plus those of Wave 3b (the loader in an app bundle, see check-wave3b.sh
# item 6).
WAVE_FILES="configure.ac include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c dlls/ntdll/unix/virtual.c dlls/ntdll/unix/server.c dlls/ntdll/unix/unix_private.h dlls/ntdll/unix/loader.c loader/main.c"
# PE sources whose objects item 9 compares with the wave base (without the old slot define)
PE_COMPARE="dlls/ntdll/aarch64-windows/signal_arm64.o:dlls/ntdll/signal_arm64.c
dlls/ntdll/aarch64-windows/thread.o:dlls/ntdll/thread.c
dlls/kernelbase/aarch64-windows/thread.o:dlls/kernelbase/thread.c
dlls/msvcrt/aarch64-windows/thread.o:dlls/msvcrt/thread.c"

# A new prefix would otherwise wait on the Mono and Gecko install dialogs.
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
# CHECK_ITEMS limits the run to some items ("build" rebuilds Wine and the test programs).
CHECK_ITEMS=${CHECK_ITEMS:-"build 1 2 3 4 5 6 7 8 9"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
run_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$t" "$@"; }

WORK=$EVIDENCE_DIR/work
mkdir -p "$WORK"
MINGW_BIN=$TOOLCHAIN_DIR/bin
OBJDUMP=$MINGW_BIN/llvm-objdump
READOBJ=$MINGW_BIN/llvm-readobj
WINE=$BUILD_DIR/wine
LOADER=$BUILD_DIR/loader/wine
SERVER=$BUILD_DIR/server/wineserver
TESTS_OUT=$EVIDENCE_DIR/programs
mkdir -p "$TESTS_OUT"

# compile_cmd OBJ SRC: the build's own compile command for OBJ, on one line
compile_cmd() {
    (cd "$BUILD_DIR" && make -n -W "$SRC_DIR/$2" "$1" 2>/dev/null) \
        | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | grep -F -- "-c -o $1 " | head -1
}
cleanup_prefix() {
    WINEPREFIX=$1 run_timeout 30 "$SERVER" -k >/dev/null 2>&1
    WINEPREFIX=$1 run_timeout 60 "$SERVER" -w >/dev/null 2>&1
    rm -rf "$1"
}
# entitlement keys of a signed file, one per line
entitlement_keys() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null | perl -ne 'print "$1\n" while /<key>([^<]*)<\/key>/g'
}

########################################################################
# Build: Wine and the test programs
########################################################################
BUILD_KIND=incremental
[ "$FULL_BUILD" = yes ] && BUILD_KIND=full
if want build; then
echo "== build: macos/build-wine.sh ($BUILD_KIND) and the test programs"
blog=$EVIDENCE_DIR/build-$BUILD_KIND.log
df -h "$HOME" | tail -1 >"$EVIDENCE_DIR/disk-before-$BUILD_KIND.txt"
if [ "$BUILD_KIND" = full ]; then
    echo "removing $BUILD_DIR for a full build" >"$blog"
    rm -rf "$BUILD_DIR"
else
    : >"$blog"
fi
start=$(date +%s)
"$PROTON_DIR/macos/build-wine.sh" >>"$blog" 2>&1
bstatus=$?
end=$(date +%s)
df -h "$HOME" | tail -1 >"$EVIDENCE_DIR/disk-after-$BUILD_KIND.txt"
echo "kind=$BUILD_KIND exit=$bstatus wall_seconds=$((end - start)) log=$blog" >"$EVIDENCE_DIR/build-$BUILD_KIND-result.txt"
if [ $bstatus = 0 ]; then
    pass build "build-wine.sh ($BUILD_KIND) exit 0 in $((end - start))s ($blog)"
else
    fail build "build-wine.sh ($BUILD_KIND) exited $bstatus ($blog)"
fi
fi  # build

# Test programs: the build's own winegcc for aarch64-windows, against Wine's CRT (winecrt0 +
# ucrtbase). No TSD slot define: NtCurrentTeb() in them reads x18.
build_program() {
    local name=$1 log=$TESTS_OUT/$1.build.log
    rm -f "$TESTS_OUT/$name.exe"
    {
        echo "\$ winegcc -b aarch64-w64-mingw32 $name.c (Wine CRT)"
        PATH=$MINGW_BIN:$PATH "$BUILD_DIR/tools/winegcc/winegcc" -v --wine-objdir "$BUILD_DIR" -b aarch64-w64-mingw32 \
            -mconsole -O2 -Wall -D_UCRT -I"$SRC_DIR/include/msvcrt" -I"$SRC_DIR/include" \
            -o "$TESTS_OUT/$name.exe" "$SCRIPT_DIR/$name.c" \
            "$BUILD_DIR/dlls/winecrt0/aarch64-windows/libwinecrt0.a" "$BUILD_DIR/dlls/ucrtbase/aarch64-windows/libucrtbase.a" \
            "$BUILD_DIR/dlls/kernel32/aarch64-windows/libkernel32.a" "$BUILD_DIR/dlls/ntdll/aarch64-windows/libntdll.a"
        echo "exit=$?"
        "$OBJDUMP" -p "$TESTS_OUT/$name.exe" | grep 'DLL Name'
    } >"$log" 2>&1
    [ -f "$TESTS_OUT/$name.exe" ]
}
if want build; then
    for p in hello teb_test wx_test; do
        if build_program $p; then pass build "$p.exe built ($TESTS_OUT/$p.build.log)"; else fail build "$p.exe did not build ($TESTS_OUT/$p.build.log)"; fi
    done
fi

########################################################################
# Item 1: the loader's signature and entitlement
########################################################################
if want 1; then
echo "== item 1: loader signature ($BUILD_KIND build)"
clog=$EVIDENCE_DIR/item1-codesign-$BUILD_KIND.log
ok=yes
: >"$clog"
launcher=$(cd "$BUILD_DIR" && readlink wine)
for f in "$LOADER" "$BUILD_DIR/${launcher:-wine}"; do
    {
        echo "=== $f"
        ls -l "$f"
        echo "\$ codesign -d --entitlements - --xml $f"
        codesign -d --entitlements - --xml "$f" 2>&1; echo
        echo "\$ codesign -dv $f"
        codesign -dv "$f" 2>&1
        echo "\$ codesign --verify --verbose=2 $f"
        codesign --verify --verbose=2 "$f" 2>&1
        echo "verify exit=$?"
    } >>"$clog"
    codesign --verify "$f" 2>/dev/null || ok=no
    keys=$(entitlement_keys "$f" | paste -sd, -)
    echo "entitlement keys: ${keys:-<none>}" >>"$clog"
    [ "$keys" = "$X18_ENTITLEMENT" ] || ok=no
    codesign -d --entitlements - --xml "$f" 2>/dev/null | grep -q "<key>$X18_ENTITLEMENT</key><true/>" || ok=no
done
skeys=$(entitlement_keys "$SERVER" | paste -sd, -)
{ echo "=== $SERVER (must not carry the entitlement)"; codesign -dv "$SERVER" 2>&1; echo "entitlement keys: ${skeys:-<none>}"; } >>"$clog"
[ -z "$skeys" ] || ok=no
if [ $ok = yes ]; then
    pass 1 "loader/wine and $launcher: exactly $X18_ENTITLEMENT, signature verifies; wineserver has no entitlements ($BUILD_KIND build; $clog)"
else
    fail 1 "loader entitlements or signature wrong after the $BUILD_KIND build ($clog)"
fi
fi  # item 1

########################################################################
# Item 2: no TSD slot TEB loads; NtCurrentTeb() reads x18
########################################################################
if want 2; then
echo "== item 2: TEB access in the aarch64-windows PE modules"
xsum=$EVIDENCE_DIR/item2-teb-access.txt
xdir=$EVIDENCE_DIR/item2-modules
rm -rf "$xdir"; mkdir -p "$xdir"
modules=$(cd "$BUILD_DIR" && find . -path '*/aarch64-windows/*' -type f \
          \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.acm' -o -name '*.ax' \
             -o -name '*.com' -o -name '*.cpl' -o -name '*.ocx' -o -name '*.msstyles' \) | sed 's|^\./||' | sort)
nmod=0; nslot=0; nmrs=0; nx18=0
: >"$xdir/per-module.tsv"; : >"$xdir/slot-loads.txt"
for m in $modules; do
    nmod=$((nmod + 1))
    "$OBJDUMP" -d "$BUILD_DIR/$m" 2>/dev/null >"$WORK/dis.tmp"
    # a slot load: mrs xN, TPIDRRO_EL0 followed within 3 instructions by ldr [xN, #0x30]
    s=$(perl -ne 'BEGIN { $n = 0; $r = ""; $left = 0 }
                  if (/mrs\s+(x\d+), TPIDRRO_EL0/i) { $r = $1; $left = 3; $mrs = $_; next }
                  if ($left > 0) { $left--; if (/ldr\s+x\d+, \[\Q$r\E, #0x30\]/) { $n++; print STDERR "$mrs$_"; $left = 0 } }
                  END { print "$n\n" }' "$WORK/dis.tmp" 2>>"$xdir/slot-loads.txt")
    mrs=$(grep -ci 'mrs.*tpidrro_el0' "$WORK/dis.tmp")
    x=$(grep -c -E '\[x18(, #0x[0-9a-f]+)?\]|mov\s+x[0-9]+, x18$' "$WORK/dis.tmp")
    nslot=$((nslot + s)); nmrs=$((nmrs + mrs)); nx18=$((nx18 + x))
    printf '%s\t%s\t%s\t%s\n' "$m" "$s" "$mrs" "$x" >>"$xdir/per-module.tsv"
done
rm -f "$WORK/dis.tmp"
NTDLL=$BUILD_DIR/dlls/ntdll/aarch64-windows/ntdll.dll
base=0x$("$OBJDUMP" -p "$NTDLL" | awk '/^ImageBase/ {print $2}')
fn_ok=yes
{
    echo "PE modules scanned: $nmod (every *.dll *.exe *.sys *.drv *.acm *.ax *.com *.cpl *.ocx *.msstyles under */aarch64-windows/)"
    echo "TSD slot TEB loads (mrs TPIDRRO_EL0 then ldr [..,#0x30]): $nslot   (any mrs TPIDRRO_EL0: $nmrs)"
    echo "TEB accesses through x18 ([x18, ...] or mov xN, x18): $nx18"
    echo "--- named modules: slot loads, mrs TPIDRRO_EL0, x18 accesses"
    grep -E '/(ntdll|kernelbase|msvcrt|ucrtbase)\.dll' "$xdir/per-module.tsv"
    echo "--- NtCurrentTeb() as ntdll.dll compiles it (it is exported on i386 only): exported functions that"
    echo "    only read the TEB, disassembled at their export RVA (ImageBase $base)"
} >"$xsum"
for fn in RtlGetCurrentPeb RtlGetLastWin32Error RtlGetFrame; do
    rva=$("$READOBJ" --coff-exports "$NTDLL" | grep -A1 "Name: $fn\$" | sed -n 's/.*RVA: //p')
    if [ -z "$rva" ]; then fn_ok=no; echo "$fn: not exported" >>"$xsum"; continue; fi
    addr=$(printf '0x%x' $((base + rva)))
    "$OBJDUMP" -d --start-address="$addr" --stop-address=$(printf '0x%x' $((base + rva + 12))) "$NTDLL" \
        | grep -E '^\s*[0-9a-f]+:' >"$WORK/fn.dis"
    { echo "$fn (RVA $rva):"; cat "$WORK/fn.dis"; } >>"$xsum"
    grep -q -E '\[x18, #0x[0-9a-f]+\]|mov[[:space:]]+x[0-9]+, x18$' "$WORK/fn.dis" || fn_ok=no
    grep -qi 'tpidrro_el0' "$WORK/fn.dis" && fn_ok=no
done
echo "--- slot loads found (must be none)" >>"$xsum"
head -20 "$xdir/slot-loads.txt" >>"$xsum"
if [ "$nslot" = 0 ] && [ "$fn_ok" = yes ] && [ "$nx18" -gt 0 ] && [ "$nmod" -gt 600 ]; then
    pass 2 "$nmod PE modules: no TSD slot TEB loads, $nx18 TEB accesses through x18; RtlGetCurrentPeb/RtlGetLastWin32Error/RtlGetFrame take the TEB from x18 ($xsum)"
else
    fail 2 "$nslot TSD slot TEB loads, $nx18 x18 accesses, ntdll TEB readers through x18: $fn_ok ($xsum)"
fi
fi  # item 2

########################################################################
# Item 3: wine hello.exe, HELLO_RUNS runs
########################################################################
if want 3; then
echo "== item 3: wine hello.exe x $HELLO_RUNS"
hdir=$EVIDENCE_DIR/item3-hello
rm -rf "$hdir"; mkdir -p "$hdir"
PREFIX=$BUILD_DIR/wave3a-prefix-hello
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hpass=0
for i in $(seq 1 "$HELLO_RUNS"); do
    t=$RUN_TIMEOUT; [ $i = 1 ] && t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
    echo "\$ WINEPREFIX=$PREFIX WINEDLLOVERRIDES=$WINEDLLOVERRIDES $WINE $TESTS_OUT/hello.exe" >"$hdir/run$i.log"
    WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/hello.exe" >"$hdir/run$i.stdout" 2>"$hdir/run$i.stderr"
    rc=$?
    { echo "--- stdout"; cat "$hdir/run$i.stdout"; echo "--- stderr"; cat "$hdir/run$i.stderr"; echo "exit=$rc"; } >>"$hdir/run$i.log"
    line=no; tr -d '\r' <"$hdir/run$i.stdout" | grep -qx 'hello from Windows ARM64 code on macOS' && line=yes
    [ "$rc" = 0 ] && [ $line = yes ] && hpass=$((hpass + 1))
    echo "run $i: exit=$rc line=$line" >>"$hdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$hpass" = "$HELLO_RUNS" ]; then
    pass 3 "hello.exe printed its line and exited 0 in $hpass/$HELLO_RUNS runs, the first in a fresh prefix ($hdir/summary.txt)"
else
    fail 3 "hello.exe passed $hpass/$HELLO_RUNS runs ($hdir/summary.txt)"
fi
fi  # item 3

########################################################################
# Item 4: wine teb_test.exe (x18), TEB_TEST_RUNS runs
########################################################################
if want 4; then
echo "== item 4: wine teb_test.exe x $TEB_TEST_RUNS"
tdir=$EVIDENCE_DIR/item4-teb_test
rm -rf "$tdir"; mkdir -p "$tdir"
PREFIX=$BUILD_DIR/wave3a-prefix-teb
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
tpass=0
for i in $(seq 1 "$TEB_TEST_RUNS"); do
    t=$RUN_TIMEOUT; [ $i = 1 ] && t=$WINEBOOT_TIMEOUT
    WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/teb_test.exe" >"$tdir/run$i.out" 2>"$tdir/run$i.stderr"
    rc=$?
    echo "exit=$rc" >>"$tdir/run$i.out"
    kinds=$(grep -o -E '^thread [0-9a-f]+ \((main|CreateThread|thread pool)' "$tdir/run$i.out" | sed 's/.*(//' | sort | uniq -c | paste -sd' ' -)
    if [ "$rc" = 0 ] && grep -q '^teb_test: PASS' "$tdir/run$i.out" && grep -q 'TEB read from x18' "$tdir/run$i.out" && \
       grep -q main <<<"$kinds" && grep -q CreateThread <<<"$kinds" && grep -q 'thread pool' <<<"$kinds"; then
        tpass=$((tpass + 1))
    fi
    echo "run $i: exit=$rc $(grep -E '^teb_test: [0-9]+ checks' "$tdir/run$i.out") threads: $kinds" >>"$tdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$tpass" = "$TEB_TEST_RUNS" ]; then
    pass 4 "teb_test.exe (raw x18 == TEB on main, CreateThread and thread pool threads) passed $tpass/$TEB_TEST_RUNS runs ($tdir/summary.txt)"
else
    fail 4 "teb_test.exe passed $tpass/$TEB_TEST_RUNS runs ($tdir/summary.txt)"
fi
fi  # item 4

########################################################################
# Item 5: negative control, the loader without the entitlement
########################################################################
if want 5; then
echo "== item 5: loader signed without the x18 entitlement"
nlog=$EVIDENCE_DIR/item5-no-entitlement.log
PREFIX=$BUILD_DIR/wave3a-prefix-noent
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
# both run Windows code: the wine launcher loads ntdll.so itself, and child processes start from loader/wine
launcher=$(cd "$BUILD_DIR" && readlink wine)
LOADERS="$LOADER $BUILD_DIR/${launcher:-wine}"
resign() { for f in $LOADERS; do codesign --force --sign - --entitlements "$ENTITLEMENTS" "$f" >>"$nlog" 2>&1; done; }
trap resign EXIT
: >"$nlog"
for f in $LOADERS; do
    {
        echo "\$ codesign --force --sign - $f   (ad hoc, no entitlements)"
        codesign --force --sign - "$f" 2>&1
        echo "entitlement keys now: $(entitlement_keys "$f" | paste -sd, -)"
    } >>"$nlog"
done
echo "\$ WINEPREFIX=$PREFIX WINEDEBUG=+loaddll,+process $WINE $TESTS_OUT/hello.exe" >>"$nlog"
WINEPREFIX=$PREFIX WINEDEBUG=+loaddll,+process run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/hello.exe" \
    >"$WORK/item5.stdout" 2>"$WORK/item5.stderr"
nrc=$?
{ echo "--- stdout"; cat "$WORK/item5.stdout"; echo "--- stderr"; cat "$WORK/item5.stderr"; echo "exit=$nrc"; } >>"$nlog"
cleanup_prefix "$PREFIX"
echo "--- signing with the entitlement again" >>"$nlog"
resign
trap - EXIT
after=""
for f in $LOADERS; do
    k=$(entitlement_keys "$f" | paste -sd, -)
    codesign --verify "$f" 2>/dev/null || k="$k(unverified)"
    echo "$f: entitlement keys after: $k" >>"$nlog"
    after="$after $k"
done
after=${after# }
msg=$(grep -m1 "$X18_ENTITLEMENT" "$WORK/item5.stderr")
nload=$(grep -c 'trace:loaddll' "$WORK/item5.stderr")
if [ "$nrc" != 0 ] && [ -n "$msg" ] && [ "$nload" = 0 ] && ! grep -q 'hello from' "$WORK/item5.stdout" && \
   [ "$after" = "$X18_ENTITLEMENT $X18_ENTITLEMENT" ]; then
    pass 5 "loader/wine and the launcher without the entitlement: exit=$nrc, no PE module loaded, message: '$msg'; entitlement restored on both ($nlog)"
else
    fail 5 "without the entitlement: exit=$nrc, PE modules loaded: $nload, message: '${msg:-none}', keys after: '$after' ($nlog)"
fi
fi  # item 5

########################################################################
# Item 6: wine wx_test.exe
########################################################################
if want 6; then
echo "== item 6: wine wx_test.exe x $WX_RUNS"
wdir=$EVIDENCE_DIR/item6-wx_test
rm -rf "$wdir"; mkdir -p "$wdir"
PREFIX=$BUILD_DIR/wave3a-prefix-wx
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
wpass=0
for i in $(seq 1 "$WX_RUNS"); do
    t=$RUN_TIMEOUT; [ $i = 1 ] && t=$WINEBOOT_TIMEOUT
    WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/wx_test.exe" >"$wdir/run$i.out" 2>"$wdir/run$i.stderr"
    rc=$?
    echo "exit=$rc" >>"$wdir/run$i.out"
    [ "$rc" = 0 ] && grep -q '^wx_test: PASS' "$wdir/run$i.out" && \
        [ "$(grep -c -E '^[a-k]: ' "$wdir/run$i.out")" = 11 ] && wpass=$((wpass + 1))
    { echo "run $i: exit=$rc"; grep -E '^[a-k]: |^wx_test: |^FAIL' "$wdir/run$i.out" | head -20; } >>"$wdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$wpass" = "$WX_RUNS" ]; then
    pass 6 "wx_test.exe parts a-k passed $wpass/$WX_RUNS runs ($wdir/summary.txt)"
else
    fail 6 "wx_test.exe passed $wpass/$WX_RUNS runs ($wdir/summary.txt)"
fi
fi  # item 6

########################################################################
# Item 7: wineboot -u, WINEBOOT_RUNS runs in a fresh prefix each
########################################################################
if want 7; then
echo "== item 7: wineboot -u x $WINEBOOT_RUNS"
bdir=$EVIDENCE_DIR/item7-wineboot
rm -rf "$bdir"; mkdir -p "$bdir"
PREFIX=$BUILD_DIR/wave3a-prefix-boot
bpass=0
for i in $(seq 1 "$WINEBOOT_RUNS"); do
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    blog=$bdir/run$i.log
    echo "\$ WINEPREFIX=$PREFIX WINEDEBUG=+pid,+seh,+loaddll,+process WINEDLLOVERRIDES=$WINEDLLOVERRIDES $WINE wineboot -u" >"$blog"
    start=$(date +%s)
    WINEPREFIX=$PREFIX WINEDEBUG=+pid,+seh,+loaddll,+process run_timeout "$WINEBOOT_TIMEOUT" "$WINE" wineboot -u >>"$blog" 2>&1
    rc=$?
    # let the services (winedevice.exe among them) finish before judging the run
    WINEPREFIX=$PREFIX run_timeout 120 "$SERVER" -w >>"$blog" 2>&1
    wrc=$?
    end=$(date +%s)
    echo "exit=$rc wineserver_wait=$wrc seconds=$((end - start))" >>"$blog"
    cleanup_prefix "$PREFIX"
    # pids of winedevice.exe processes (+pid prefixes every line with the process id)
    wpids=$(grep -E 'trace:loaddll:.*winedevice\.exe' "$blog" | sed -n 's/^\([0-9a-f]\{4,\}\):.*/\1/p' | sort -u | paste -sd' ' -)
    nav=0
    for p in $wpids; do nav=$((nav + $(grep -c -E "^$p:[0-9a-f]+:trace:seh:dispatch_exception code=c0000005" "$blog"))); done
    nheap=$(grep -c 'Invalid handle 0000000000000000' "$blog")
    nwd=$(echo $wpids | wc -w | tr -d ' ')
    status=FAIL
    [ "$rc" = 0 ] && [ "$nav" = 0 ] && [ "$nheap" = 0 ] && [ "$nwd" -gt 0 ] && { status=PASS; bpass=$((bpass + 1)); }
    echo "run $i: $status wineboot exit=$rc, winedevice processes: $nwd ($wpids), c0000005 in winedevice: $nav, null heap handles: $nheap, $((end - start))s" \
        | tee -a "$bdir/summary.txt"
done
if [ "$bpass" = "$WINEBOOT_RUNS" ]; then
    pass 7 "wineboot -u clean in $bpass/$WINEBOOT_RUNS fresh prefixes: exit 0, no access violation in winedevice.exe, no null heap ($bdir/summary.txt)"
else
    fail 7 "wineboot -u clean in $bpass/$WINEBOOT_RUNS runs ($bdir/summary.txt)"
fi
fi  # item 7

########################################################################
# Item 8: regression of Waves 1, 2a and 2b
########################################################################
if want 8; then
echo "== item 8: Wave 1, 2a and 2b regression"
R1=$EVIDENCE_DIR/regression-wave1
R2=$EVIDENCE_DIR/regression-wave2a
R3=$EVIDENCE_DIR/regression-wave2b
rm -rf "$R1" "$R2" "$R3"; mkdir -p "$R1" "$R2" "$R3"
cp "$BUILD_ROOT/evidence/wave1/build-clean-result.txt" "$R1/" 2>/dev/null
EVIDENCE_DIR=$R1 "$PROTON_DIR/macos/tests/check-wave1.sh" >"$R1/check-wave1.out" 2>&1
EVIDENCE_DIR=$R2 "$PROTON_DIR/macos/tests/check-wave2a.sh" >"$R2/check-wave2a.out" 2>&1
EVIDENCE_DIR=$R3 "$PROTON_DIR/macos/tests/check-wave2b.sh" >"$R3/check-wave2b.out" 2>&1
rok=yes
for r in "$R1" "$R2" "$R3"; do
    [ -s "$r/check-summary.txt" ] || rok=no
    grep -q '^FAIL' "$r/check-summary.txt" 2>/dev/null && rok=no
done
if [ $rok = yes ]; then
    pass 8 "check-wave1.sh, check-wave2a.sh and check-wave2b.sh: no FAIL ($R1/check-summary.txt, $R2/check-summary.txt, $R3/check-summary.txt)"
else
    fail 8 "regressions: $(cat "$R1/check-summary.txt" "$R2/check-summary.txt" "$R3/check-summary.txt" 2>/dev/null | grep '^FAIL' | cut -c1-60 | paste -sd';' -) ($R1, $R2, $R3)"
fi
fi  # item 8

########################################################################
# Item 9: other targets unchanged
########################################################################
if want 9; then
echo "== item 9: other targets unchanged"
glog=$EVIDENCE_DIR/item9-guards.log
ulog=$EVIDENCE_DIR/item9-unifdef.log
clog=$EVIDENCE_DIR/item9-codegen.log
dlog=$EVIDENCE_DIR/item9-diff.log
: >"$ulog"; : >"$clog"
ok=yes
# The new code: the diff against the upstream base, each hunk with the preprocessor lines that guard it
{
    echo "\$ git -C wine diff $WINE_BASE HEAD -- dlls/ntdll/unix/virtual.c dlls/ntdll/unix/signal_arm64.c dlls/ntdll/unix/server.c: every added line with its enclosing #if stack"
    echo "  (the other files are back to the upstream text or, configure.ac, scoped to darwin*-aarch64 by Wave 2a; see item9-unifdef.log)"
    git -C "$WINE_DIR" diff --stat "$WINE_BASE" HEAD -- dlls/ntdll/unix/virtual.c dlls/ntdll/unix/signal_arm64.c include/winnt.h dlls/ntdll/signal_arm64.c
    for f in dlls/ntdll/unix/virtual.c dlls/ntdll/unix/signal_arm64.c dlls/ntdll/unix/server.c; do
        git -C "$WINE_DIR" show "HEAD:$f" >"$WORK/guard.c"
        # each line added since the upstream base, prefixed with the stack of #if conditions it is in
        git -C "$WINE_DIR" diff -U0 "$WINE_BASE" HEAD -- "$f" | sed -n 's/^@@ -[0-9,]* +\([0-9]*\),\{0,1\}\([0-9]*\) @@.*/\1 \2/p' >"$WORK/hunks"
        perl -e '
            my ($file, $hunks) = @ARGV; open my $fh, "<", $file or die; my @lines = <$fh>;
            open my $hh, "<", $hunks or die; my %added;
            while (<$hh>) { my ($s, $n) = split; $n = 1 if $n eq ""; $added{$_} = 1 for $s .. $s + $n - 1; }
            my @stack; my $i = 0;
            for my $l (@lines) {
                $i++;
                if ($l =~ /^\s*#\s*(if|ifdef|ifndef)\b(.*)/) { push @stack, "$1$2"; }
                elsif ($l =~ /^\s*#\s*(elif)\b(.*)/) { $stack[-1] = "$1$2 (after $stack[-1])"; }
                elsif ($l =~ /^\s*#\s*else\b/) { $stack[-1] = "else of $stack[-1]"; }
                elsif ($l =~ /^\s*#\s*endif\b/) { pop @stack; }
                next unless $added{$i};
                my @g = grep { /__APPLE__|WX_EXCLUSIVE_HOST/ } @stack;
                # Wave 2a: the shared user data address is a define, 0x7ffe0000 on every other target
                my $kind = @g ? "guarded" : ($l =~ /WINE_USER_SHARED_DATA_ADDR/ ? "wave2a-define" : "UNGUARDED");
                printf "%s %s:%d [%s] %s", $kind, $ARGV[2], $i, join(" > ", map { s/\s+/ /gr } @stack), $l;
            }' "$WORK/guard.c" "$WORK/hunks" "$f"
    done
} >"$glog" 2>&1
nadd=$(grep -c -E '^(guarded|UNGUARDED|wave2a-define) ' "$glog")
# a preprocessor line or blank line that opens or closes a guard is allowed outside it
# (a lone brace can be the old one that diff pairs with a new block; the unifdef check below
# catches any real change outside the guards)
nung=$(grep '^UNGUARDED ' "$glog" | grep -v -E '\] (#\s*(if|ifdef|endif|else)|\s*[{}]?\s*$)' | wc -l | tr -d ' ')
[ "$nung" = 0 ] && [ "$nadd" -gt 0 ] || ok=no
grep -q -E '^#define WX_EXCLUSIVE_HOST' <(git -C "$WINE_DIR" show HEAD:dlls/ntdll/unix/virtual.c) || ok=no
echo "--- added lines: $nadd, outside a __APPLE__/WX_EXCLUSIVE_HOST guard (other than the guard lines): $nung" >>"$glog"
# Source level: with the macOS conditions undefined, every touched file is the wave base text, and
# the PE files are the wave base text without the old slot define (WX_EXCLUSIVE_HOST is defined
# only under __APPLE__ && __aarch64__).
for f in include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c dlls/ntdll/unix/virtual.c dlls/ntdll/unix/server.c dlls/ntdll/unix/unix_private.h; do
    git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$f" | unifdef -U__APPLE__ -UWX_EXCLUSIVE_HOST -UWINE_TEB_TSD_SLOT | cat -s >"$WORK/unifdef.base" 2>/dev/null
    git -C "$WINE_DIR" show "HEAD:$f" | unifdef -U__APPLE__ -UWX_EXCLUSIVE_HOST -UWINE_TEB_TSD_SLOT | cat -s >"$WORK/unifdef.new" 2>/dev/null
    if cmp -s "$WORK/unifdef.base" "$WORK/unifdef.new"; then
        echo "unifdef -U__APPLE__ -UWX_EXCLUSIVE_HOST -UWINE_TEB_TSD_SLOT $f: identical to $WINE_WAVE_BASE" >>"$ulog"
    else
        ok=no; echo "unifdef $f: DIFFERS from $WINE_WAVE_BASE" >>"$ulog"
        diff "$WORK/unifdef.base" "$WORK/unifdef.new" | head -20 >>"$ulog"
    fi
done
# include/winnt.h, dlls/ntdll/signal_arm64.c and configure.ac are back to the upstream base text
for f in include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c configure.ac; do
    n=$(git -C "$WINE_DIR" diff "$WINE_BASE" HEAD -- "$f" | grep -c -E '^[-+][^-+]')
    echo "$f: lines changed since upstream base $WINE_BASE: $n" >>"$ulog"
done
for f in include/winnt.h dlls/ntdll/signal_arm64.c; do
    [ -z "$(git -C "$WINE_DIR" diff "$WINE_BASE" HEAD -- "$f")" ] || { ok=no; echo "$f: still differs from $WINE_BASE" >>"$ulog"; }
done
git -C "$WINE_DIR" diff "$WINE_BASE" HEAD -- configure.ac | grep -i 'tsd' && { ok=no; echo "configure.ac: slot define left" >>"$ulog"; }
# Object code: Unix files for x86_64 macOS (no aarch64 code), PE files for aarch64- and x86_64-windows
SAME_LINES="-Wno-builtin-macro-redefined -D__LINE__=0"
for v in base new; do
    rev=$WINE_WAVE_BASE; [ $v = new ] && rev=HEAD
    rm -rf "$WORK/$v"; mkdir -p "$WORK/$v"
    git -C "$WINE_DIR" archive "$rev" include dlls/ntdll dlls/kernelbase dlls/msvcrt | tar -x -C "$WORK/$v"
done
for site in "dlls/ntdll/unix/virtual.o:dlls/ntdll/unix/virtual.c"; do
    obj=${site%%:*}; src=${site#*:}
    cmd=$(compile_cmd "$obj" "$src")
    tag=$(echo "$obj" | tr / _)-x86_64-macos
    for v in base new; do
        tree=$WORK/$v
        vcmd=${cmd/ $SRC_DIR\/$src / $tree/$src }
        vcmd=${vcmd//-I$SRC_DIR\/include/-I$tree/include}
        vcmd=${vcmd/-c -o $obj /-c -o $WORK/$tag.$v.o -I$tree/$(dirname "$src") }
        (cd "$BUILD_DIR" && eval "$vcmd -target x86_64-apple-macos11 -g0 -fmacro-prefix-map=$tree=/wine $SAME_LINES") >"$WORK/$tag.$v.err" 2>&1
        objdump -d -r -s "$WORK/$tag.$v.o" 2>/dev/null | sed 1,2d >"$WORK/$tag.$v.dis"
    done
    if [ -s "$WORK/$tag.new.dis" ] && cmp -s "$WORK/$tag.base.dis" "$WORK/$tag.new.dis"; then
        echo "unix x86_64-apple-macos $src: object code identical to $WINE_WAVE_BASE ($(wc -l <"$WORK/$tag.new.dis" | tr -d ' ') lines)" >>"$clog"
    else
        ok=no; echo "unix x86_64-apple-macos $src: OBJECT CODE DIFFERS or did not compile: $(head -2 "$WORK/$tag.new.err" | tr '\n' ' ')" >>"$clog"
        diff "$WORK/$tag.base.dis" "$WORK/$tag.new.dis" 2>/dev/null | head -20 >>"$clog"
    fi
done
while IFS=: read -r obj src; do
    cmd=$(compile_cmd "$obj" "$src")
    [ -n "$cmd" ] || { ok=no; echo "$obj: no compile command" >>"$clog"; continue; }
    for tgt in aarch64 x86_64; do
        tcmd=${cmd/$MINGW_BIN\/aarch64-w64-mingw32-clang/$MINGW_BIN/$tgt-w64-mingw32-clang}
        tag=$(echo "$obj" | tr / _)-$tgt
        for v in base new; do
            tree=$WORK/$v
            vcmd=${tcmd/ $SRC_DIR\/$src / $tree/$src }
            vcmd=${vcmd//-I$SRC_DIR\/include/-I$tree/include}
            vcmd=${vcmd/-c -o $obj /-c -o $WORK/$tag.$v.o -I$tree/$(dirname "$src") }
            (cd "$BUILD_DIR" && eval "$vcmd -g0 -fmacro-prefix-map=$tree=/wine $SAME_LINES") >>"$clog" 2>&1 \
                || { ok=no; echo "$tag $v: compile failed" >>"$clog"; }
            "$OBJDUMP" -d -r -s "$WORK/$tag.$v.o" 2>&1 | sed 1,2d >"$WORK/$tag.$v.dis"
        done
        if [ -s "$WORK/$tag.new.dis" ] && cmp -s "$WORK/$tag.base.dis" "$WORK/$tag.new.dis"; then
            echo "$tgt-windows $src (the base without its slot define): object code identical ($(wc -l <"$WORK/$tag.new.dis" | tr -d ' ') lines)" >>"$clog"
        else
            ok=no; echo "$tgt-windows $src: OBJECT CODE DIFFERS" >>"$clog"
            diff "$WORK/$tag.base.dis" "$WORK/$tag.new.dis" | head -20 >>"$clog"
        fi
    done
done <<<"$PE_COMPARE"
{
    echo "\$ git -C wine diff --stat $WINE_WAVE_BASE HEAD"
    git -C "$WINE_DIR" diff --stat "$WINE_WAVE_BASE" HEAD
    echo "\$ git -C wine log --format='%h %s' $WINE_WAVE_BASE..HEAD"
    git -C "$WINE_DIR" log --format='%h %s' "$WINE_WAVE_BASE..HEAD"
    echo "\$ git diff --stat $SUPER_WAVE_BASE HEAD   (superproject)"
    git -C "$PROTON_DIR" diff --stat "$SUPER_WAVE_BASE" HEAD
    echo "\$ git diff --raw $SUPER_WAVE_BASE HEAD -- wine   (submodule pointer must be unchanged)"
    git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine
} >"$dlog" 2>&1
wbad=""
for f in $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD); do
    case " $WAVE_FILES " in *" $f "*) ;; *) wbad="$wbad $f" ;; esac
done
sbad=$(git -C "$PROTON_DIR" diff --name-only "$SUPER_WAVE_BASE" HEAD | grep -v '^macos/')
[ -n "$(git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine)" ] && sbad="$sbad wine(pointer)"
[ -n "$wbad" ] && ok=no
[ -n "$sbad" ] && ok=no
if [ $ok = yes ]; then
    pass 9 "$nadd lines added since $WINE_BASE in unix/virtual.c, unix/signal_arm64.c and unix/server.c all under __APPLE__/WX_EXCLUSIVE_HOST; unifdef'd sources and x86_64-macOS/PE objects identical to $WINE_WAVE_BASE; winnt.h and PE signal_arm64.c back to $WINE_BASE; wine changes only in $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD | tr '\n' ' ')($glog, $ulog, $clog, $dlog)"
else
    fail 9 "unguarded lines: $nung; wine unexpected:${wbad:- none}; superproject: '$(echo $sbad)' ($glog, $ulog, $clog, $dlog)"
fi
fi  # item 9

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
exit $FAILED
