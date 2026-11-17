#!/bin/bash
#
# Wave 2b acceptance check for the native arm64 macOS Wine build: Windows ARM64 code runs in a
# native macOS process without x18. The macOS kernel doesn't preserve x18, so Wine keeps the TEB
# in TSD slot WINE_TEB_TSD_SLOT (6, reserved by Apple for Windows code) and its ARM64 PE code
# reads it from there.
#
#   macos/tests/check-wave2b.sh
#
# Wave 3a reverted the slot: the custom x18 ABI keeps x18, so the TEB is in x18 again. Without the
# slot define, item 1 is retired (INFO) and item 2 is inverted: the PE modules must read x18 and
# must not load the TEB from the slot. check-wave3a.sh checks the x18 TEB in full.
#
# Items (pass/fail unless marked INFO):
#   1  slot mechanism: configured slot, standalone probe 10 runs, slot set on every Wine thread
#      (INFO, retired, without the slot define)
#   2  no instruction in any built aarch64-windows PE module (or the test programs) reads x18
#      (without the slot define: they read x18, and no TSD slot TEB loads are left)
#   3  wine hello.exe prints its line and exits 0 (the go/no-go milestone)
#   4  wine teb_test.exe passes all checks, 20 runs
#   5  INFO: wineboot -u in a fresh prefix: exit status, first failure, x18-related or not
#   6  regression: check-wave1.sh items 1-4, 6 and check-wave2a.sh items 1-4, 6
#   8  syscall stack arguments: the Unix side reads them from 8-byte slots, as the ARM64 PE
#      callers (AAPCS64) pass them, not packed as Apple's arm64 ABI (DarwinPCS) would
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
# Wine files this wave may change, plus those of Wave 3a (x18 opt-in, W^X page flipping, see
# check-wave3a.sh item 9) and Wave 3b (the loader in an app bundle and the ARM64 ID registers, see check-wave3b.sh item 6)
# and Wave 4 (winemac.drv's table for DXMT, see check-wave4.sh item 7).
WAVE_FILES="configure.ac include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c include/minwindef.h dlls/ntdll/unix/unix_private.h dlls/ntdll/unix/file.c dlls/ntdll/unix/loader.c dlls/ntdll/unix/virtual.c dlls/ntdll/unix/server.c loader/main.c dlls/ntdll/unix/system.c dlls/winemac.drv/macdrv.h dlls/winemac.drv/window.c dlls/uiautomationcore/uia_client.c dlls/winegstreamer/media-converter/media-converter.h dlls/winebus.sys/bus_iohid.c"
# Wine files that later waves change, which check-wave5.sh checks the guards of (PE code, guarded
# by configure's WINE_MACOS_AARCH64, and configure.ac itself)
LATER_WAVE_FILES="dlls/mfreadwrite/reader.c configure.ac dlls/winegstreamer/video_decoder.c dlls/winegstreamer/video_processor.c dlls/winemac.drv/cocoa_display.m programs/tabtip/tabtip.c dlls/win32u/font.c dlls/kernelbase/process.c"
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

# A new prefix would otherwise wait on the Mono and Gecko install dialogs.
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
# CHECK_ITEMS limits the run to some items ("build" rebuilds Wine and the test programs).
CHECK_ITEMS=${CHECK_ITEMS:-"build 8 1 2 3 4 5 6 7"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
info() { RESULTS+=("INFO  item $1: $2"); echo "INFO  item $1: $2"; }
# set once the build is configured: Wave 3a removed the slot define
SLOT_RETIRED=no
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
# Proton's wineserver starts to shut down the moment its last process exits (server/main.c sets
# master_socket_timeout to 0, where Wine's own default is 3 seconds). A wine that starts right
# after another one has exited then meets a server that is going away: it brings Wine's
# services up again, and now and then it is dropped while the server exits, which ends it with
# status 0 and no output. For a run of launches in one prefix, hold_server starts a server that
# waits 10 seconds for the next process instead; cleanup_prefix ends it.
hold_server() { WINEPREFIX=$1 run_timeout 30 "$SERVER" -p10 >/dev/null 2>&1; }

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
[ -z "$PE_SLOT_FLAG" ] && [ -z "$UNIX_SLOT_FLAG" ] && [ -f "$BUILD_DIR/Makefile" ] && SLOT_RETIRED=yes

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
# Item 8: syscall stack argument layout
########################################################################
# PE code calls syscalls with the Windows ARM64 (AAPCS64) convention: arguments 9 and up go in
# 8-byte stack slots whatever their size. Apple's arm64 ABI packs stack arguments at their natural
# alignment, so a Unix-side syscall built with it reads e.g. two ULONGs from one slot. The
# dispatcher copies the slots verbatim, so the Unix syscall functions must use the slot layout.
if want 8; then
echo "== item 8: syscall stack argument layout"
alog=$EVIDENCE_DIR/item8-stack-args.log
ok=yes
: >"$alog"
# (a) header level: a WINAPI function compiled with the build's own Unix command for ntdll
cat >"$WORK/stack_probe.c" <<'EOP'
#include <stdarg.h>
#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"
extern void stack_probe_use( ULONG, ULONG, BOOLEAN, USHORT );
NTSTATUS WINAPI stack_probe( HANDLE a, HANDLE b, void *c, ULONG_PTR d, SIZE_T e, void *f, void *g,
                             ULONG h, ULONG alloc_type, ULONG protect, BOOLEAN x, USHORT y )
{
    stack_probe_use( alloc_type, protect, x, y );
    return 0;
}
EOP
cmd=$(compile_cmd dlls/ntdll/unix/virtual.o dlls/ntdll/unix/virtual.c)
if [ -n "$cmd" ]; then
    pcmd=${cmd/ $SRC_DIR\/dlls\/ntdll\/unix\/virtual.c / $WORK/stack_probe.c }
    pcmd=${pcmd/-c -o dlls\/ntdll\/unix\/virtual.o /-c -o $WORK/stack_probe.o }
    (cd "$BUILD_DIR" && eval "$pcmd") >>"$alog" 2>&1 || { ok=no; echo "stack probe: compile failed" >>"$alog"; }
    objdump -d --no-show-raw-insn "$WORK/stack_probe.o" >"$WORK/stack_probe.dis" 2>&1
    { echo "--- (a) WINAPI stack_probe(8 register args, ULONG alloc_type, ULONG protect, BOOLEAN x, USHORT y), build's Unix command"
      echo "    AAPCS64 slots: alloc_type +0x10, protect +0x18, x +0x20, y +0x28 from the caller's sp"
      sed 1,4d "$WORK/stack_probe.dis"; } >>"$alog"
else
    ok=no; echo "no compile command for dlls/ntdll/unix/virtual.o" >>"$alog"
fi
# (b) every 64-bit syscall of ntdll and win32u with stack arguments, in the built .so files
SA_SCAN=$WORK/stack_scan.pl
cat >"$SA_SCAN" <<'EOP'
# stdin: objdump -d of a Mach-O; args: syscall names. For each, every access to the caller's frame
# ([x29, #off] with off >= 0x10 after the standard prologue) must touch 8-byte slots only.
use strict; use warnings;
my %want = map { ("_$_" => 1) } @ARGV;
$want{$ENV{SA_EXTRA_SYMBOL}} = 1 if $ENV{SA_EXTRA_SYMBOL}; my ($fn, %acc, %seen);
while (<STDIN>) {
    if (/^[0-9a-f]+ <(.*)>:/) { $fn = $want{$1} ? $1 : undef; $seen{$fn} = 1 if $fn; next; }
    next unless $fn && /^\s*[0-9a-f]+:\s+(\S+)\s+(.*)$/;
    my ($op, $ops) = ($1, $2);
    next unless $op =~ /^(ld|st)/ && $ops =~ /\[x29, #0x([0-9a-f]+)\]/;
    my $off = hex($1); next if $off < 0x10;
    my @r = ($ops =~ /\b([wx])\d+\b/g);
    my $sz = ($op =~ /b$/) ? 1 : ($op =~ /h$/) ? 2 : ($op =~ /sw$/ || ($r[0] // "x") eq "w") ? 4 : 8;
    my @offs = ($op =~ /^(ldp|stp)/) ? ($off, $off + $sz) : ($off);
    for my $o (@offs) { push @{$acc{$fn}}, sprintf("%s %s at 0x%x%s", $op, $ops, $o, $o % 8 ? " PACKED" : ""); }
}
for my $n (sort keys %want) {
    if (!$seen{$n}) { print "MISSING $n\n"; next; }
    my @a = @{$acc{$n} // []};
    my $bad = grep { /PACKED/ } @a;
    printf "%s %s: %s\n", (@a ? ($bad ? "BAD" : "OK") : "NOFRAMEACCESS"), $n, join("; ", @a);
}
EOP
for lib in ntdll:dlls/ntdll/ntsyscalls.h:dlls/ntdll/ntdll.so win32u:dlls/win32u/win32syscalls.h:dlls/win32u/win32u.so; do
    IFS=: read -r name hdr so <<<"$lib"
    names=$(sed -n '/^#ifdef _WIN64/,/^#else/p' "$SRC_DIR/$hdr" \
            | sed -n 's/.*SYSCALL_ENTRY( *0x[0-9a-f]*, *\([A-Za-z0-9_]*\), *\([0-9]*\) *).*/\1 \2/p' | awk '$2 > 64 {print $1}')
    objdump -d --no-show-raw-insn "$BUILD_DIR/$so" 2>/dev/null | perl "$SA_SCAN" $names >"$WORK/item8-$name.txt"
    { echo "--- (b) $name: 64-bit syscalls with more than 64 bytes of arguments (stack arguments): $(echo $names | wc -w | tr -d ' ')"
      cat "$WORK/item8-$name.txt"; } >>"$alog"
done
probe_offs=$(SA_EXTRA_SYMBOL=ltmp0 perl "$SA_SCAN" stack_probe <"$WORK/stack_probe.dis" 2>/dev/null \
             | grep -o -E 'at 0x[0-9a-f]+' | sed 's/at //' | sort -u | paste -sd, -)
probe_offs=${probe_offs:-none}
# the probe must load from 8-byte slots only (the frame offset of the first slot depends on the prologue)
for o in $(echo "$probe_offs" | tr , ' '); do [ "$o" = none ] || [ $((o % 8)) = 0 ] || ok=no; done
[ "$probe_offs" = none ] && ok=no
nbad=$(cat "$WORK"/item8-*.txt | grep -c '^BAD ')
nok=$(cat "$WORK"/item8-*.txt | grep -c '^OK ')
nnoacc=$(cat "$WORK"/item8-*.txt | grep -c '^NOFRAMEACCESS ')
nmiss=$(cat "$WORK"/item8-*.txt | grep -c '^MISSING ')
grep -q '^OK _NtMapViewOfSection:' "$WORK/item8-ntdll.txt" || ok=no
[ "$nbad" = 0 ] || ok=no
echo "--- summary: probe frame offsets $probe_offs; syscalls OK $nok, BAD (packed) $nbad, no caller-frame access $nnoacc, missing $nmiss" >>"$alog"
mv=$(grep '_NtMapViewOfSection:' "$WORK/item8-ntdll.txt" | cut -c1-160)
if [ $ok = yes ]; then
    pass 8 "stack arguments in 8-byte slots: probe loads at $probe_offs; $nok syscalls OK, 0 packed ($mv) ($alog)"
else
    fail 8 "probe loads at $probe_offs; $nbad syscalls read packed stack arguments ($mv) ($alog)"
fi
fi  # item 8

########################################################################
# Item 1: slot mechanism
########################################################################
if want 1 && [ $SLOT_RETIRED = yes ]; then
    info 1 "retired: configure gives no WINE_TEB_TSD_SLOT define (Wave 3a: the TEB is in x18 again, see check-wave3a.sh items 2 and 4)"
elif want 1; then
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
if [ $SLOT_RETIRED = yes ]; then
    # inverted: the TEB is in x18, so the modules read it, and no slot loads are left
    nslot=$(while IFS= read -r f; do "$OBJDUMP" -d "$f" 2>/dev/null | grep -i -A2 'mrs.*tpidrro_el0' | grep -c 'ldr.*#0x30\]'; done <"$xdir/modules.txt" | awk '{n += $1} END {print n + 0}')
    echo "--- inverted (no slot define): TSD slot TEB loads (mrs TPIDRRO_EL0; ...; ldr [..,#0x30]): $nslot" >>"$xsum"
    ntdll_r=$(awk -F'\t' '$1 ~ "/aarch64-windows/ntdll.dll$" {print $3}' "$xdir/per-module.tsv")
    if [ "$total_r" -gt 0 ] && [ "${ntdll_r:-0}" -gt 0 ] && [ "$nslot" = 0 ] && [ "$nmod" -gt 600 ] && [ -f "$TESTS_OUT/teb_test.exe" ]; then
        pass 2 "inverted for Wave 3a: $nmod PE modules + test programs read x18 ($total_r reads, ntdll.dll $ntdll_r) and load no TEB from the slot ($xsum)"
    else
        fail 2 "inverted for Wave 3a: $total_r x18 reads (ntdll.dll ${ntdll_r:-0}), $nslot slot loads in $nmod modules ($xsum)"
    fi
elif [ "$total_r" = 0 ] && [ "$nmod" -gt 600 ] && [ -f "$TESTS_OUT/teb_test.exe" ] && [ -f "$TESTS_OUT/hello.exe" ]; then
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
hold_server "$PREFIX"
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
# (the CRT writes text-mode stdout: \r\n line ends)
if [ "$hstatus" = 0 ] && tr -d '\r' <"$hout.stdout" | grep -qx 'hello from Windows ARM64 code on macOS' && \
   [ "$dstatus" = 0 ] && tr -d '\r' <"$hout.debug-run" | grep -qx 'hello from Windows ARM64 code on macOS'; then
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
hold_server "$PREFIX"
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
    git -C "$WINE_DIR" archive "$rev" include dlls/ntdll dlls/kernelbase dlls/msvcrt dlls/user32 dlls/win32u | tar -x -C "$WORK/$v"
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
if [ $SLOT_RETIRED = yes ]; then
    echo "aarch64-windows $src with the slot define: not checked, configure no longer gives it (Wave 3a)" >>"$clog"
elif [ -n "$PE_SLOT_FLAG" ] && echo "$cmd" | grep -q -- "$PE_SLOT_FLAG"; then
    tree=$WORK/new; vcmd=${cmd/ $SRC_DIR\/$src / $tree/$src }; vcmd=${vcmd//-I$SRC_DIR\/include/-I$tree/include}
    vcmd=${vcmd/-c -o $obj /-c -o $WORK/with-define.o -I$tree/$(dirname "$src") }
    (cd "$BUILD_DIR" && eval "$vcmd -g0 $SAME_LINES") >>"$clog" 2>&1
    n=$("$OBJDUMP" -d "$WORK/with-define.o" | grep -ci 'tpidrro_el0')
    echo "aarch64-windows with $PE_SLOT_FLAG $src: $n tpidrro_el0 reads (must be > 0)" >>"$clog"
    [ "$n" -gt 0 ] || ok=no
else
    ok=no; echo "build command for $obj lacks the slot define" >>"$clog"
fi
# Source level: with the macOS conditions undefined, every touched file is the wave base text
# (runs of blank lines squeezed, cat -s: a removed block leaves its surrounding blank lines).
for f in include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c include/minwindef.h; do
    case $f in */unix/*|include/minwindef.h) syms="-U__APPLE__" ;; *) syms="-UWINE_TEB_TSD_SLOT" ;; esac
    git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$f" | unifdef $syms | cat -s >"$WORK/unifdef.base" 2>/dev/null
    git -C "$WINE_DIR" show "HEAD:$f" | unifdef $syms | cat -s >"$WORK/unifdef.new" 2>/dev/null
    if cmp -s "$WORK/unifdef.base" "$WORK/unifdef.new"; then
        echo "unifdef $syms $f: identical to $WINE_WAVE_BASE" >>"$ulog"
    else
        ok=no; echo "unifdef $syms $f: DIFFERS from $WINE_WAVE_BASE" >>"$ulog"
        diff "$WORK/unifdef.base" "$WORK/unifdef.new" | head -20 >>"$ulog"
    fi
done
# Unix side (include/minwindef.h: __stdcall is ms_abi only for aarch64 macOS Unix code).
# Unix objects for targets without __APPLE__ or without __aarch64__: same code before and after.
# Linux libc headers aren't available here, so the Linux check compiles a probe that only needs
# Wine's headers (stdarg.h from the compiler); the macOS x86_64 check compiles real Unix files.
mkdir -p "$WORK/stubs"; : >"$WORK/stubs/ctype.h"; : >"$WORK/stubs/string.h"
cp "$WORK/stack_probe.c" "$WORK/cc_probe.c" 2>/dev/null || cat >"$WORK/cc_probe.c" <<'EOP'
#include <stdarg.h>
#include "windef.h"
#include "winternl.h"
extern void stack_probe_use( ULONG, ULONG, BOOLEAN, USHORT );
NTSTATUS WINAPI stack_probe( HANDLE a, HANDLE b, void *c, ULONG_PTR d, SIZE_T e, void *f, void *g,
                             ULONG h, ULONG alloc_type, ULONG protect, BOOLEAN x, USHORT y )
{
    stack_probe_use( alloc_type, protect, x, y );
    return 0;
}
EOP
for tgt in aarch64-linux-gnu x86_64-linux-gnu x86_64-apple-macos11 arm64-apple-macos11; do
    for v in base new; do
        clang --target=$tgt -O2 -c -nostdinc -isystem "$(clang -print-resource-dir)/include" -isystem "$WORK/stubs" \
              -D__WINESRC__ -DWINE_UNIX_LIB -I"$BUILD_DIR/include" -I"$WORK/$v/include" "$WORK/cc_probe.c" \
              -o "$WORK/cc_probe.$tgt.$v.o" >"$WORK/cc_probe.$tgt.$v.err" 2>&1
        objdump -d -r "$WORK/cc_probe.$tgt.$v.o" 2>/dev/null | sed 1,2d >"$WORK/cc_probe.$tgt.$v.dis"
    done
    if [ ! -s "$WORK/cc_probe.$tgt.new.dis" ]; then
        ok=no; echo "unix $tgt WINAPI probe: compile failed: $(head -3 "$WORK/cc_probe.$tgt.new.err" | tr '\n' ' ')" >>"$clog"
    elif cmp -s "$WORK/cc_probe.$tgt.base.dis" "$WORK/cc_probe.$tgt.new.dis"; then
        echo "unix $tgt WINAPI probe (10 args, ULONG/BOOLEAN/USHORT stack args): object code identical" >>"$clog"
        [ $tgt = arm64-apple-macos11 ] && { ok=no; echo "  ... but aarch64 macOS should have changed" >>"$clog"; }
    else
        echo "unix $tgt WINAPI probe: object code differs (expected only for arm64-apple-macos11):" >>"$clog"
        diff "$WORK/cc_probe.$tgt.base.dis" "$WORK/cc_probe.$tgt.new.dis" | head -30 >>"$clog"
        [ $tgt = arm64-apple-macos11 ] || ok=no
    fi
done
for site in "dlls/ntdll/unix/virtual.o:dlls/ntdll/unix/virtual.c" "dlls/ntdll/unix/file.o:dlls/ntdll/unix/file.c" "dlls/ntdll/unix/loader.o:dlls/ntdll/unix/loader.c" "dlls/win32u/message.o:dlls/win32u/message.c"; do
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
        echo "unix x86_64-apple-macos $src: object code identical ($(wc -l <"$WORK/$tag.new.dis" | tr -d ' ') lines)" >>"$clog"
    elif [ ! -s "$WORK/$tag.new.dis" ]; then
        echo "unix x86_64-apple-macos $src: could not compile with this host's config.h (not checked): $(head -2 "$WORK/$tag.new.err" | tr '\n' ' ')" >>"$clog"
    else
        ok=no; echo "unix x86_64-apple-macos $src: OBJECT CODE DIFFERS" >>"$clog"
        diff "$WORK/$tag.base.dis" "$WORK/$tag.new.dis" | head -20 >>"$clog"
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
    case " $WAVE_FILES $LATER_WAVE_FILES " in *" $f "*) ;; *) wbad="$wbad $f" ;; esac
done
[ -z "$(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD)" ] && { ok=no; wbad="$wbad (no wine changes)"; }
sbad=$(git -C "$PROTON_DIR" diff --name-only "$SUPER_WAVE_BASE" HEAD | grep -v '^macos/' | grep -v -x -F -e lsteamclient/unixlib.cpp -e lsteamclient/unix_steam_input_manual.cpp)
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
