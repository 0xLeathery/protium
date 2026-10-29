#!/bin/bash
#
# Wave 2b acceptance check for the native arm64 macOS Wine build: Windows ARM64 code runs in a
# native macOS process without x18. The macOS kernel doesn't preserve x18, so Wine keeps the TEB
# in TSD slot WINE_TEB_TSD_SLOT (6, reserved by Apple for Windows code) and its ARM64 PE code
# reads it from there.
#
#   macos/tests/check-wave2b.sh
#
# Items (pass/fail unless marked INFO):
#   1  slot mechanism: configured slot, standalone probe 10 runs, slot set on every Wine thread
#   2  no instruction in any built aarch64-windows PE module (or the test programs) reads x18
#   3  wine hello.exe prints its line and exits 0 (the go/no-go milestone)
#   4  wine teb_test.exe passes all checks, 20 runs
#   5  INFO: wineboot -u in a fresh prefix: exit status, first failure, x18-related or not
#   6  regression: check-wave1.sh items 1-4, 6 and check-wave2a.sh items 1-4, 6
#   7  other targets unchanged: PE objects without the define identical to the wave base for
#      aarch64-windows and x86_64-windows; Unix changes only under __APPLE__; diff scope
# The build (macos/build-wine.sh, incremental) and the test programs are built first ("build").
# Logs go to $EVIDENCE_DIR.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
WINE_DIR=$PROTON_DIR/wine
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
SRC_DIR=${SRC_DIR:-$BUILD_ROOT/wine-src}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave2b}
# item 2 of an earlier run on the unchanged build, for the before/after x18 counts
BEFORE_DIR=${BEFORE_DIR:-$BUILD_ROOT/evidence/wave2b-before}
# wine commit this wave starts from (tip of macos-arm64 after Wave 2a) and the superproject equivalent
WINE_WAVE_BASE=${WINE_WAVE_BASE:-d30ba1b032f90f2d2e0e7f5bbb27980bdc522ffa}
SUPER_WAVE_BASE=${SUPER_WAVE_BASE:-5c10f7c13a672f6db7f83d69db30f908e5655832}
WINEBOOT_TIMEOUT=${WINEBOOT_TIMEOUT:-180}
RUN_TIMEOUT=${RUN_TIMEOUT:-120}
TEB_TEST_RUNS=${TEB_TEST_RUNS:-20}
PROBE_RUNS=${PROBE_RUNS:-10}
# Wine files this wave may change.
WAVE_FILES="configure.ac include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c"
# PE sources whose objects item 7 compares without the define: the PE file this wave changes, and
# users of NtCurrentTeb() (include/winnt.h) in several modules. object:source
PE_COMPARE="dlls/ntdll/aarch64-windows/signal_arm64.o:dlls/ntdll/signal_arm64.c
dlls/ntdll/aarch64-windows/thread.o:dlls/ntdll/thread.c
dlls/ntdll/aarch64-windows/loader.o:dlls/ntdll/loader.c
dlls/ntdll/aarch64-windows/exception.o:dlls/ntdll/exception.c
dlls/kernelbase/aarch64-windows/thread.o:dlls/kernelbase/thread.c
dlls/kernelbase/aarch64-windows/process.o:dlls/kernelbase/process.c
dlls/msvcrt/aarch64-windows/thread.o:dlls/msvcrt/thread.c
dlls/user32/aarch64-windows/message.o:dlls/user32/message.c"

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
# CHECK_ITEMS limits the run to some items ("build" rebuilds Wine and the test programs).
CHECK_ITEMS=${CHECK_ITEMS:-"build 1 2 3 4 5 6 7"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
info() { RESULTS+=("INFO  item $1: $2"); echo "INFO  item $1: $2"; }
run_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$t" "$@"; }

WORK=$EVIDENCE_DIR/work
mkdir -p "$WORK"
MINGW_BIN=$TOOLCHAIN_DIR/bin
OBJDUMP=$MINGW_BIN/llvm-objdump
WINE=$BUILD_DIR/wine
SERVER=$BUILD_DIR/server/wineserver
TESTS_OUT=$EVIDENCE_DIR/programs
mkdir -p "$TESTS_OUT"

# compile_cmd OBJ SRC: the build's own compile command for OBJ, on one line
compile_cmd() {
    (cd "$BUILD_DIR" && make -n -W "$SRC_DIR/$2" "$1" 2>/dev/null) \
        | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | grep -F -- "-c -o $1 " | head -1
}
# configured slot define from a Makefile flags line (empty when configure didn't set one)
slot_flag() {
    sed -n "s/^$1 = .*\(-DWINE_TEB_TSD_SLOT=[0-9][0-9]*\).*/\1/p" "$BUILD_DIR/Makefile" 2>/dev/null | head -1
}
cleanup_prefix() {
    WINEPREFIX=$1 run_timeout 30 "$SERVER" -k >/dev/null 2>&1
    WINEPREFIX=$1 run_timeout 30 "$SERVER" -w >/dev/null 2>&1
    rm -rf "$1"
}

########################################################################
# Build: Wine (incremental) and the test programs
########################################################################
if want build; then
echo "== build: macos/build-wine.sh (incremental) and the test programs"
blog=$EVIDENCE_DIR/build-incremental.log
df -h "$HOME" | tail -1 >"$EVIDENCE_DIR/disk-before.txt"
start=$(date +%s)
"$PROTON_DIR/macos/build-wine.sh" >"$blog" 2>&1
bstatus=$?
end=$(date +%s)
df -h "$HOME" | tail -1 >"$EVIDENCE_DIR/disk-after.txt"
echo "exit=$bstatus wall_seconds=$((end - start)) log=$blog" >"$EVIDENCE_DIR/build-incremental-result.txt"
if [ $bstatus = 0 ]; then
    pass build "build-wine.sh exit 0 in $((end - start))s ($blog)"
else
    fail build "build-wine.sh exited $bstatus ($blog)"
fi
fi  # build

PE_SLOT_FLAG=$(slot_flag aarch64_EXTRACFLAGS)
UNIX_SLOT_FLAG=$(slot_flag EXTRACFLAGS)
SLOT=${PE_SLOT_FLAG#-DWINE_TEB_TSD_SLOT=}

# Test programs: the build's own winegcc for aarch64-windows, against Wine's CRT (winecrt0 +
# ucrtbase), with the build's slot define so that NtCurrentTeb() in them reads the slot too.
build_program() {
    local name=$1 log=$TESTS_OUT/$1.build.log
    rm -f "$TESTS_OUT/$name.exe"
    {
        echo "\$ winegcc -b aarch64-w64-mingw32 ${PE_SLOT_FLAG:-<no slot define>} $name.c (Wine CRT)"
        PATH=$MINGW_BIN:$PATH "$BUILD_DIR/tools/winegcc/winegcc" -v --wine-objdir "$BUILD_DIR" -b aarch64-w64-mingw32 \
            -mconsole -O2 -Wall $PE_SLOT_FLAG -D_UCRT -I"$SRC_DIR/include/msvcrt" -I"$SRC_DIR/include" \
            -o "$TESTS_OUT/$name.exe" "$SCRIPT_DIR/$name.c" \
            "$BUILD_DIR/dlls/winecrt0/aarch64-windows/libwinecrt0.a" "$BUILD_DIR/dlls/ucrtbase/aarch64-windows/libucrtbase.a" \
            "$BUILD_DIR/dlls/kernel32/aarch64-windows/libkernel32.a" "$BUILD_DIR/dlls/ntdll/aarch64-windows/libntdll.a"
        echo "exit=$?"
        "$OBJDUMP" -p "$TESTS_OUT/$name.exe" | grep 'DLL Name'
    } >"$log" 2>&1
    [ -f "$TESTS_OUT/$name.exe" ]
}
if want build; then
    for p in hello teb_test; do
        if build_program $p; then pass build "$p.exe built ($TESTS_OUT/$p.build.log)"; else fail build "$p.exe did not build ($TESTS_OUT/$p.build.log)"; fi
    done
fi

########################################################################
# Item 1: slot mechanism
########################################################################
if want 1; then
echo "== item 1: TSD slot mechanism"
slog=$EVIDENCE_DIR/item1-slot.log
ok=yes
{
    echo "--- configure: slot define for the aarch64 PE side and the Unix side (no other PE arch)"
    grep -n -E '^[a-z0-9_]*EXTRACFLAGS = ' "$BUILD_DIR/Makefile" | grep -o -E '^[0-9]+:[a-z0-9_]*EXTRACFLAGS|-DWINE_TEB_TSD_SLOT=[0-9]+' | paste -sd' ' -
    echo "aarch64 PE: ${PE_SLOT_FLAG:-<none>}  unix: ${UNIX_SLOT_FLAG:-<none>}"
} >"$slog" 2>&1
[ -n "$PE_SLOT_FLAG" ] && [ "$PE_SLOT_FLAG" = "$UNIX_SLOT_FLAG" ] || ok=no
for a in x86_64 i386 arm arm64ec; do
    [ -n "$(slot_flag ${a}_EXTRACFLAGS)" ] && { ok=no; echo "unexpected slot define for $a PE code" >>"$slog"; }
done
# Standalone probe, PROBE_RUNS runs: slot reserved and free, survives preemption/syscalls/signals
PROBE=$WORK/tsd_slot_probe
cc -O2 -Wall -o "$PROBE" "$SCRIPT_DIR/tsd_slot_probe.c" -framework CoreFoundation >"$WORK/tsd_slot_probe.build.log" 2>&1 \
    || { ok=no; echo "probe build failed ($WORK/tsd_slot_probe.build.log)" >>"$slog"; }
plog=$EVIDENCE_DIR/item1-probe-runs.log
: >"$plog"
probe_pass=0
for i in $(seq 1 "$PROBE_RUNS"); do
    echo "=== probe run $i: $PROBE ${SLOT:-6}" >>"$plog"
    run_timeout 120 "$PROBE" "${SLOT:-6}" >>"$plog" 2>&1
    rc=$?
    echo "exit=$rc" >>"$plog"
    [ $rc = 0 ] && probe_pass=$((probe_pass + 1))
done
results=$(grep '^RESULT' "$plog" | sort | uniq -c)
keys=$(sed -n 's/^pthread_key_create -> 0, key //p' "$plog" | sort -n | uniq | paste -sd, -)
echo "--- probe: $probe_pass/$PROBE_RUNS runs passed; results: $results; dynamic keys seen: $keys" >>"$slog"
[ "$probe_pass" = "$PROBE_RUNS" ] && [ "$(grep -c "^RESULT PASS slot=${SLOT:-x} " "$plog")" = "$PROBE_RUNS" ] || ok=no
# In Wine: teb_test reads the raw slot on the main thread, CreateThread threads and thread pool
# workers (threads Wine creates) and compares it with the TEB the Unix side reports.
PREFIX=$BUILD_DIR/wave2b-prefix-slot
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
tlog=$EVIDENCE_DIR/item1-teb_test-threads.log
if [ -f "$TESTS_OUT/teb_test.exe" ]; then
    WINEPREFIX=$PREFIX run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/teb_test.exe" >"$tlog" 2>"$tlog.stderr"
    echo "exit=$?" >>"$tlog"
else
    echo "teb_test.exe not built" >"$tlog"
fi
cleanup_prefix "$PREFIX"
nthreads=$(grep -c -E '^thread [0-9a-f]+ \(' "$tlog")
nkinds=$(grep -o -E '^thread [0-9a-f]+ \((main|CreateThread|thread pool)' "$tlog" | sed 's/.*(//' | sort | uniq -c | paste -sd' ' -)
nuniq=$(grep -o -E '^thread [0-9a-f]+' "$tlog" | sort -u | wc -l | tr -d ' ')
{
    echo "--- teb_test in Wine ($tlog): $(head -1 "$tlog")"
    echo "threads reporting a matching slot: $nthreads ($nkinds), distinct thread ids: $nuniq"
    grep -E '^teb_test: ' "$tlog"
} >>"$slog"
grep -q "^teb_test: TEB read from TSD slot ${SLOT:-x} " "$tlog" && grep -q '^teb_test: PASS' "$tlog" && grep -q '^exit=0' "$tlog" || ok=no
grep -q 'thread pool' <<<"$nkinds" && grep -q 'CreateThread' <<<"$nkinds" && grep -q 'main' <<<"$nkinds" || ok=no
if [ $ok = yes ]; then
    pass 1 "slot $SLOT (TPIDRRO_EL0+$(printf '%#x' $((SLOT * 8)))), Apple-reserved static slot written directly; configure gives the same define to aarch64 PE and Unix; probe $probe_pass/$PROBE_RUNS runs pass (dynamic keys seen: $keys); in Wine the slot holds the TEB on $nuniq threads ($nkinds) ($slog, $plog, $tlog)"
else
    fail 1 "see $slog ($plog, $tlog)"
fi
fi  # item 1

########################################################################
# Item 2: no instruction reads x18 in the aarch64-windows PE modules
########################################################################
# x18_scan: llvm-objdump -d on stdin -> one line per instruction naming x18/w18, classified as
# R (reads x18: any source operand, an address register, a read-modify-write destination) or
# W (only writes it).
X18_SCAN=$WORK/x18_scan.pl
cat >"$X18_SCAN" <<'EOF'
use strict; use warnings;
my $fn = "?";
while (<STDIN>) {
    if (/^[0-9a-f]+ <(.*)>:/) { $fn = $1; next; }
    next unless /^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)\s*(.*)$/;
    my ($addr, $op, $insn) = ($1, $3, $4);
    $insn =~ s{\s*//.*$}{};
    next unless $insn =~ /\b[xw]18\b/;
    my $kind = "R";
    my $mem = ($insn =~ /\[([^\]]*)\]/) ? $1 : "";
    my $regs = $insn; $regs =~ s/\[[^\]]*\]!?//; my @ops = map { s/^\s+|\s+$//gr } split /,/, $regs;
    my @hit = grep { $ops[$_] =~ /^[xw]18$/ } 0 .. $#ops;
    if ($mem =~ /\b[xw]18\b/) { $kind = "R" }
    elsif ($op =~ /^(cmp|cmn|tst|ccmp|ccmn|cbz|cbnz|tbz|tbnz|br|blr|braa|brab|blraa|blrab|ret|msr|dc|ic|at|sys|prfm|movk|bfi|bfxil|bfm|bfc|cas\w*)$/) { $kind = "R" }
    elsif ($op =~ /^st(l?)x[rp]/) { $kind = (@hit == 1 && $hit[0] == 0) ? "W" : "R" }
    elsif ($op =~ /^st/) { $kind = "R" }
    elsif ($op =~ /^(ld(add|clr|eor|set|smax|smin|umax|umin)\w*|swp\w*)$/) { $kind = (@hit && !grep { $_ != 1 } @hit) ? "W" : "R" }
    elsif ($op =~ /^ld/) { $kind = "W" }        # destinations only (address checked above)
    elsif (@hit && !grep { $_ != 0 } @hit) { $kind = "W" }   # first operand is the destination
    print "$kind $addr <$fn> $op $insn\n";
}
EOF
if want 2; then
echo "== item 2: x18 in the aarch64-windows PE modules"
xdir=$EVIDENCE_DIR/item2-x18
rm -rf "$xdir"; mkdir -p "$xdir"
xsum=$EVIDENCE_DIR/item2-x18-summary.txt
modules=$(cd "$BUILD_DIR" && find . -path '*/aarch64-windows/*' -type f \
          \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.acm' -o -name '*.ax' \
             -o -name '*.com' -o -name '*.cpl' -o -name '*.ocx' -o -name '*.msstyles' \) | sed 's|^\./||' | sort)
{ for m in $modules; do echo "$BUILD_DIR/$m"; done; ls "$TESTS_OUT"/*.exe 2>/dev/null; } >"$xdir/modules.txt"
total_r=0; total_w=0; total_m=0; total_loose=0; nmod=0
: >"$xdir/per-module.tsv"
while IFS= read -r f; do
    nmod=$((nmod + 1))
    rel=${f#$BUILD_DIR/}; rel=${rel#$EVIDENCE_DIR/}
    "$OBJDUMP" -d "$f" 2>/dev/null >"$WORK/dis.tmp"
    loose=$(grep -c 'x18' "$WORK/dis.tmp")
    perl "$X18_SCAN" <"$WORK/dis.tmp" >"$WORK/x18.tmp"
    r=$(grep -c '^R ' "$WORK/x18.tmp"); w=$(grep -c '^W ' "$WORK/x18.tmp"); m=$(wc -l <"$WORK/x18.tmp" | tr -d ' ')
    total_r=$((total_r + r)); total_w=$((total_w + w)); total_m=$((total_m + m)); total_loose=$((total_loose + loose))
    printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$m" "$r" "$w" "$loose" >>"$xdir/per-module.tsv"
    [ "$m" -gt 0 ] && sed "s|^|$rel: |" "$WORK/x18.tmp" >>"$xdir/x18-instructions.txt"
done <"$xdir/modules.txt"
rm -f "$WORK/dis.tmp" "$WORK/x18.tmp"
named() { awk -F'\t' -v m="$1" '$1 ~ "/aarch64-windows/"m"$" {print $2" (reads "$3", loose grep "$5")"}' "$2" 2>/dev/null; }
{
    echo "PE modules scanned: $nmod (every *.dll *.exe *.sys *.drv *.acm *.ax *.com *.cpl *.ocx *.msstyles under */aarch64-windows/, plus the test programs)"
    echo "instructions naming x18/w18 as a register: $total_m (reads: $total_r, writes only: $total_w); lines matching a loose 'x18' grep: $total_loose"
    echo "--- named modules now: instructions naming x18 (reads, loose grep count)"
    for n in ntdll.dll kernelbase.dll msvcrt.dll ucrtbase.dll; do echo "$n: $(named $n "$xdir/per-module.tsv")"; done
    if [ -f "$BEFORE_DIR/item2-x18/per-module.tsv" ]; then
        echo "--- the same modules before this wave ($BEFORE_DIR)"
        for n in ntdll.dll kernelbase.dll msvcrt.dll ucrtbase.dll; do echo "$n: $(named $n "$BEFORE_DIR/item2-x18/per-module.tsv")"; done
        echo "before totals: $(head -2 "$BEFORE_DIR/item2-x18-summary.txt" | tail -1)"
    fi
    echo "--- remaining instructions that read x18 (must be none)"
    grep -E '^[^:]+: R ' "$xdir/x18-instructions.txt" 2>/dev/null | head -50
    echo "--- remaining writes of x18, by instruction pattern"
    grep -E '^[^:]+: W ' "$xdir/x18-instructions.txt" 2>/dev/null | sed -E 's/^[^:]+: W [0-9a-f]+ //' | sed -E 's/#0x[0-9a-f]+/#imm/g' | sort | uniq -c | sort -rn | head -30
    echo "--- modules with x18 references"
    awk -F'\t' '$2 > 0' "$xdir/per-module.tsv"
} >"$xsum" 2>&1
if [ "$total_r" = 0 ] && [ "$nmod" -gt 600 ] && [ -f "$TESTS_OUT/teb_test.exe" ] && [ -f "$TESTS_OUT/hello.exe" ]; then
    pass 2 "$nmod PE modules + test programs: no instruction reads x18 ($total_w writes only; $xsum)"
else
    fail 2 "$total_r instructions read x18 in $nmod modules ($xsum, $xdir/x18-instructions.txt)"
fi
fi  # item 2

########################################################################
# Item 3: wine hello.exe (go/no-go)
########################################################################
if want 3; then
echo "== item 3: wine hello.exe"
hout=$EVIDENCE_DIR/item3-hello.out
hlog=$EVIDENCE_DIR/item3-hello-debug.log
PREFIX=$BUILD_DIR/wave2b-prefix-hello
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
if [ -f "$TESTS_OUT/hello.exe" ]; then
    # first run in a fresh prefix (Wine sets the prefix up first), with the requested channels
    echo "\$ WINEPREFIX=$PREFIX WINEDEBUG=+seh,+loaddll,+process $WINE hello.exe   (fresh prefix, timeout ${WINEBOOT_TIMEOUT}s)" >"$hlog"
    WINEPREFIX=$PREFIX WINEDEBUG=+seh,+loaddll,+process run_timeout "$WINEBOOT_TIMEOUT" "$WINE" "$TESTS_OUT/hello.exe" \
        >"$hout.debug-run" 2>>"$hlog"
    dstatus=$?
    echo "exit=$dstatus" >>"$hlog"
    # then the plain run: full output and exit status
    { echo "\$ WINEPREFIX=$PREFIX $WINE hello.exe"; } >"$hout"
    WINEPREFIX=$PREFIX run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/hello.exe" >"$hout.stdout" 2>"$hout.stderr"
    hstatus=$?
    { echo "--- stdout"; cat "$hout.stdout"; echo "--- stderr"; cat "$hout.stderr"; echo "exit=$hstatus"; } >>"$hout"
else
    dstatus=none; hstatus=none
    echo "hello.exe not built" >"$hout"
fi
cleanup_prefix "$PREFIX"
if [ "$hstatus" = 0 ] && grep -qx 'hello from Windows ARM64 code on macOS' "$hout.stdout" && \
   [ "$dstatus" = 0 ] && grep -qx 'hello from Windows ARM64 code on macOS' "$hout.debug-run"; then
    pass 3 "wine hello.exe printed its line and exited 0 (debug run in a fresh prefix exit $dstatus; $hout, $hlog)"
else
    fail 3 "hello.exe exit=$hstatus (debug run exit=$dstatus) ($hout, $hlog)"
fi
fi  # item 3

########################################################################
# Item 4: wine teb_test.exe, TEB_TEST_RUNS runs
########################################################################
if want 4; then
echo "== item 4: wine teb_test.exe x $TEB_TEST_RUNS"
tdir=$EVIDENCE_DIR/item4-teb_test
rm -rf "$tdir"; mkdir -p "$tdir"
PREFIX=$BUILD_DIR/wave2b-prefix-teb
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
tpass=0
for i in $(seq 1 "$TEB_TEST_RUNS"); do
    if [ -f "$TESTS_OUT/teb_test.exe" ]; then
        WINEPREFIX=$PREFIX run_timeout "$RUN_TIMEOUT" "$WINE" "$TESTS_OUT/teb_test.exe" >"$tdir/run$i.out" 2>"$tdir/run$i.stderr"
        rc=$?
    else
        rc=none; echo "teb_test.exe not built" >"$tdir/run$i.out"
    fi
    echo "exit=$rc" >>"$tdir/run$i.out"
    if [ "$rc" = 0 ] && grep -q '^teb_test: PASS' "$tdir/run$i.out"; then tpass=$((tpass + 1)); fi
    echo "run $i: exit=$rc $(grep -E '^teb_test: [0-9]+ checks' "$tdir/run$i.out")" >>"$tdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$tpass" = "$TEB_TEST_RUNS" ]; then
    pass 4 "teb_test.exe passed $tpass/$TEB_TEST_RUNS runs ($tdir/summary.txt)"
else
    fail 4 "teb_test.exe passed $tpass/$TEB_TEST_RUNS runs ($tdir/summary.txt)"
fi
fi  # item 4

########################################################################
# Item 5 (INFO): wineboot -u in a fresh prefix
########################################################################
if want 5; then
echo "== item 5: wineboot -u"
wlog=$EVIDENCE_DIR/item5-wineboot.log
wsum=$EVIDENCE_DIR/item5-summary.txt
PREFIX=$BUILD_DIR/wave2b-prefix-boot
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
echo "\$ WINEPREFIX=$PREFIX WINEDEBUG=+seh,+loaddll,+process $WINE wineboot -u   (timeout ${WINEBOOT_TIMEOUT}s)" >"$wlog"
WINEPREFIX=$PREFIX WINEDEBUG=+seh,+loaddll,+process run_timeout "$WINEBOOT_TIMEOUT" "$WINE" wineboot -u >>"$wlog" 2>&1
wstatus=$?
echo "exit=$wstatus" >>"$wlog"
ls -la "$PREFIX" "$PREFIX/drive_c" >"$WORK/item5-prefix.txt" 2>&1
cp "$PREFIX/system.reg" "$WORK/item5-system.reg" 2>/dev/null
cleanup_prefix "$PREFIX"
# x18-related: an exception at an instruction that reads x18 (item 2 lists them), or a fault with
# a null-based address in the first page (what a TEB read through a zeroed x18 looks like).
{
    echo "exit=$wstatus (142 = timed out)"
    echo "--- processes started"
    grep -E 'process:|Starting process|loaddll:.*\.exe' "$wlog" | grep -o -E '[A-Za-z0-9_]+\.exe' | sort | uniq -c
    echo "--- prefix contents after the run"
    cat "$WORK/item5-prefix.txt"
    echo "--- exceptions (seh)"
    grep -n -E 'seh:.*(code|exception)|Unhandled|EXCEPTION_' "$wlog" | head -30
    echo "--- errors"
    grep -n -E 'err:|wine: ' "$wlog" | head -40
    echo "--- last 30 lines"
    tail -30 "$wlog"
} >"$wsum" 2>&1
first=$(grep -m1 -E 'seh:.*code=|Unhandled|err:|wine: ' "$wlog" | cut -c1-160)
x18rel=no
if grep -E 'seh:.*code=c0000005' "$wlog" | grep -q -E 'addr(ess)?[ =]0x0*[0-9a-f]{1,3}[^0-9a-f]'; then x18rel=maybe; fi
reads=$(grep -c -E '^[^:]+: R ' "$EVIDENCE_DIR/item2-x18/x18-instructions.txt" 2>/dev/null)
echo "x18-related: $x18rel (instructions reading x18 in the PE modules: ${reads:-0}; null-page access violations: $x18rel)" >>"$wsum"
info 5 "wineboot -u exit=$wstatus; first failure: ${first:-none}; x18-related: $x18rel ($wsum, $wlog)"
fi  # item 5

########################################################################
# Item 6: regression of Waves 1 and 2a
########################################################################
if want 6; then
echo "== item 6: Wave 1 and Wave 2a regression"
R1=$EVIDENCE_DIR/wave1-regression
R2=$EVIDENCE_DIR/wave2a-regression
rm -rf "$R1" "$R2"; mkdir -p "$R1" "$R2"
cp "$BUILD_ROOT/evidence/wave1/build-clean-result.txt" "$R1/" 2>/dev/null
EVIDENCE_DIR=$R1 "$PROTON_DIR/macos/tests/check-wave1.sh" >"$R1/check-wave1.out" 2>&1
# Wave 2a: its item 2 (build) was just done above and its item 5 is the Wave 1 run above
EVIDENCE_DIR=$R2 CHECK_ITEMS="1 3 4 6" "$PROTON_DIR/macos/tests/check-wave2a.sh" >"$R2/check-wave2a.out" 2>&1
rok=yes
for i in 1 2 3 4 6; do grep -q "^PASS  item $i:" "$R1/check-summary.txt" 2>/dev/null || rok=no; done
for i in 1 3 4 6; do grep -q "^PASS  item $i:" "$R2/check-summary.txt" 2>/dev/null || rok=no; done
if [ $rok = yes ]; then
    pass 6 "check-wave1.sh items 1-4, 6 and check-wave2a.sh items 1, 3, 4, 6 pass ($R1/check-summary.txt, $R2/check-summary.txt)"
else
    fail 6 "regressions ($R1/check-summary.txt, $R2/check-summary.txt)"
fi
fi  # item 6

########################################################################
# Item 7: other targets unchanged
########################################################################
if want 7; then
echo "== item 7: other targets unchanged"
clog=$EVIDENCE_DIR/item7-codegen.log
ulog=$EVIDENCE_DIR/item7-unifdef.log
dlog=$EVIDENCE_DIR/item7-diff.log
: >"$clog"; : >"$ulog"
ok=yes
# Object code comparisons pin __LINE__ (assert() embeds line numbers) and strip paths.
SAME_LINES="-Wno-builtin-macro-redefined -D__LINE__=0"
for v in base new; do
    rev=$WINE_WAVE_BASE; [ $v = new ] && rev=HEAD
    rm -rf "$WORK/$v"; mkdir -p "$WORK/$v"
    git -C "$WINE_DIR" archive "$rev" include dlls/ntdll dlls/kernelbase dlls/msvcrt dlls/user32 | tar -x -C "$WORK/$v"
done
echo "PE objects compiled with the build's commands minus -DWINE_TEB_TSD_SLOT (what Linux and every other target get), wave base $WINE_WAVE_BASE vs HEAD, whole include/ tree from each revision" >>"$clog"
while IFS=: read -r obj src; do
    cmd=$(compile_cmd "$obj" "$src")
    [ -n "$cmd" ] || { ok=no; echo "$obj: no compile command" >>"$clog"; continue; }
    cmd=$(echo "$cmd" | sed -E 's/ -DWINE_TEB_TSD_SLOT=[^ ]*//')
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
            echo "$tgt-windows (no define) $src: object code identical ($(wc -l <"$WORK/$tag.new.dis" | tr -d ' ') lines of objdump -d -r -s)" >>"$clog"
        else
            ok=no; echo "$tgt-windows (no define) $src: OBJECT CODE DIFFERS" >>"$clog"
            diff "$WORK/$tag.base.dis" "$WORK/$tag.new.dis" | head -20 >>"$clog"
        fi
    done
done <<<"$PE_COMPARE"
# The same with the define: the aarch64 objects do change (sanity check that the comparison sees it)
obj=dlls/ntdll/aarch64-windows/signal_arm64.o; src=dlls/ntdll/signal_arm64.c
cmd=$(compile_cmd "$obj" "$src")
if [ -n "$PE_SLOT_FLAG" ] && echo "$cmd" | grep -q -- "$PE_SLOT_FLAG"; then
    tree=$WORK/new; vcmd=${cmd/ $SRC_DIR\/$src / $tree/$src }; vcmd=${vcmd//-I$SRC_DIR\/include/-I$tree/include}
    vcmd=${vcmd/-c -o $obj /-c -o $WORK/with-define.o -I$tree/$(dirname "$src") }
    (cd "$BUILD_DIR" && eval "$vcmd -g0 $SAME_LINES") >>"$clog" 2>&1
    n=$("$OBJDUMP" -d "$WORK/with-define.o" | grep -c 'tpidrro_el0')
    echo "aarch64-windows with $PE_SLOT_FLAG $src: $n tpidrro_el0 reads (must be > 0)" >>"$clog"
    [ "$n" -gt 0 ] || ok=no
else
    ok=no; echo "build command for $obj lacks the slot define" >>"$clog"
fi
# Source level: with the macOS conditions undefined, every touched file is the wave base text.
for f in include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c; do
    case $f in */unix/*) syms="-U__APPLE__" ;; *) syms="-UWINE_TEB_TSD_SLOT" ;; esac
    git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$f" | unifdef $syms >"$WORK/unifdef.base" 2>/dev/null
    git -C "$WINE_DIR" show "HEAD:$f" | unifdef $syms >"$WORK/unifdef.new" 2>/dev/null
    if cmp -s "$WORK/unifdef.base" "$WORK/unifdef.new"; then
        echo "unifdef $syms $f: identical to $WINE_WAVE_BASE" >>"$ulog"
    else
        ok=no; echo "unifdef $syms $f: DIFFERS from $WINE_WAVE_BASE" >>"$ulog"
        diff "$WORK/unifdef.base" "$WORK/unifdef.new" | head -20 >>"$ulog"
    fi
done
# configure.ac: the new define only for aarch64 Darwin hosts and only for aarch64 PE code
{
    echo "--- configure.ac changes in this wave"
    git -C "$WINE_DIR" diff "$WINE_WAVE_BASE" HEAD -- configure.ac
} >>"$ulog"
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
[ -z "$(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD)" ] && { ok=no; wbad="$wbad (no wine changes)"; }
sbad=$(git -C "$PROTON_DIR" diff --name-only "$SUPER_WAVE_BASE" HEAD | grep -v '^macos/')
[ -n "$wbad" ] && ok=no
[ -n "$sbad" ] && ok=no
if [ $ok = yes ]; then
    pass 7 "PE objects without the define identical to $WINE_WAVE_BASE for aarch64- and x86_64-windows; touched files identical with the macOS conditions undefined; wine changes only in $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD | tr '\n' ' ')($clog, $ulog, $dlog)"
else
    fail 7 "wine unexpected:${wbad:- none}; superproject outside macos/: '$(echo $sbad)' ($clog, $ulog, $dlog)"
fi
fi  # item 7

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
exit $FAILED
